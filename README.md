# agent-sandbox

`agent-sandbox` runs one command inside a transient systemd user unit whose
filesystem access is set by the kernel: everything is read-only except the
paths you list, the directories you name are hidden outright, the service
manager's own sockets are out of reach, and the run has a wall clock. It is a
single bash script with a `--probe` mode that tests each of those walls from
inside the sandbox, so you can check the confinement instead of believing it.

It was written for unattended AI agent CLI runs (a nightly `claude`, `codex` or
`aider` invocation from a timer or cron), but it knows nothing about any
particular agent: it wraps whatever command you give it.

## The problem it answers

An unattended agent runs with your user account's rights. If it decides to
`rm -rf` a directory, rewrite a config, or read a token file, nothing in the
tool stops it, because at the operating system level it is you. Deny lists
inside the agent are string matching over an infinitely variable command line;
they catch accidents and miss anything they did not anticipate, and they are
gone entirely when the agent shells out. systemd already carries the pieces for
a real boundary through per-service sandboxing directives, and `systemd-run
--user` applies them to a one-off command without a container, a VM, or root.
`agent-sandbox` composes those directives from a few flags and then tests them.

## Requirements

- Linux with systemd and a running user service manager
  (`systemctl --user show-environment` should succeed).
- bash 5, `systemd-run` and `systemctl`, awk, and the coreutils the probe uses
  (`stat`, `base64`, `head`, `ls`, `rm`, `id`, `seq`, `realpath`, `tee`,
  `mktemp`).
- All the directives used here have been in systemd for years; the tool is
  developed and tested on systemd 261. On an older systemd, run `--probe`
  first: it will tell you which walls actually stand.

No root, no container runtime, nothing to install. Copy the `agent-sandbox`
script somewhere on your PATH.

## Quickstart

```sh
# one repository writable, everything else read-only, credentials hidden,
# a two hour wall clock
./agent-sandbox \
  --cwd ~/work/project \
  --rw  ~/work/project \
  --hide ~/.ssh \
  --hide ~/.config/gcloud \
  --max-runtime 2h \
  -- my-agent --do-the-nightly-thing

# see the exact systemd-run command line without running anything
./agent-sandbox --cwd ~/work/project --rw ~/work/project --dry-run -- my-agent

# test the walls of that same configuration
./agent-sandbox --cwd ~/work/project --rw ~/work/project --hide ~/.ssh --probe
```

The command's exit status is passed through, and stdin, stdout and stderr are
connected to your terminal or pipe.

## Run the probe before you trust the sandbox

`--probe` runs a small bash payload under exactly the settings your flags
produce, and asserts each wall from inside. Every assertion prints one line,
and there are three verdicts:

- `PASS:` the wall is there, tested from inside the unit.
- `FAIL:` the wall the flags claim is not there. The command exits nonzero, so
  the probe fits in a pre-flight check or a CI job.
- `SKIP:` nothing was tested. Either you turned that wall off deliberately, or
  it cannot be tested in this configuration, or the thing it protects is
  reachable and the tool is telling you so. A run with skips exits zero and
  never prints "all assertions passed": a skipped check is not a passed check.

```
$ ./agent-sandbox --cwd /srv/work --rw /srv/work --ro /srv/law \
    --hide /srv/secrets --max-runtime 30m --probe
=== agent-sandbox --probe: assertions run inside the unit ===
PASS: writable as allowed: /srv/work
PASS: home outside the allowlist is not writable: /home/you/.agent-sandbox-probe-should-fail
PASS: / is mounted read-only inside the unit (ProtectSystem=strict)
PASS: /etc is on a read-only mount
PASS: read-only as asked: /srv/law
PASS: hidden: /srv/secrets (Permission denied)
PASS: /tmp is private: files outside the unit are not visible in it
PASS: the user bus is not connectable
PASS: no unit can be started from inside the sandbox
SKIP: these entries under /run/user/1000 are still reachable, and the processes behind them hold credentials of their own: gnupg keyring pipewire-0
SKIP: 530 processes of other users are visible in /proc (ProtectProc= has no effect on user units); ptrace_scope=1
PASS: running inside agent-sandbox-work-20260904-120000-1234.service (checked against /proc/self/cgroup)
=== payload complete: 10 passed, 0 failed, 2 skipped inside the unit ===
PASS: wall clock set on agent-sandbox-work-20260904-120000-1234.service: RuntimeMaxSec=30min (read from the manager, outside the unit)
=== agent-sandbox --probe: nothing failed, and some checks were SKIPPED above. A skipped check is not a passed check. ===
```

What it checks:

- each `--rw` path is writable;
- a path in `$HOME` that no `--rw` covers is not writable;
- `/` and `/etc` are on read-only mounts, read from `/proc/self/mountinfo`
  rather than from a write attempt (an unprivileged user cannot write `/etc`
  with or without a sandbox, so a write attempt there is a green line that
  cannot go red);
- each `--ro` path is covered by a read-only mount;
- each `--hide` path exists but has unreadable contents, and says so separately
  when there is nothing at the path at all, because that is what a typo looks
  like;
- `/tmp` is private, tested with a witness file created outside the unit;
- the user bus is not connectable and no unit can be started from inside;
- which entries under the runtime directory are still reachable (the sockets
  of processes that hold credentials of their own), and how many processes of
  other users are visible;
- with `--strict`, that `NoNewPrivileges` is set, `/proc/sys` is read-only, and
  a setuid bit cannot be set;
- the run is really inside the unit the launcher named, checked against
  `/proc/self/cgroup`;
- a wall clock is set, read from the service manager on the host side while
  the unit is alive (the confined payload cannot ask systemd anything, by
  design);
- that the payload itself ran. It opens with a header line and closes with a
  completion line, and the launcher refuses to print a verdict without both.
  Otherwise a payload that never reached the unit (a missing interpreter, a
  changed transport) would leave the host-side checks alone on screen and the
  run would read as green with nothing tested;
- with `--tmpfs-home`, that `$HOME` is a tmpfs, and that a marker written in one
  run is gone in a second run of the same profile.

The probe cleans up the files it creates, including the ones it only creates
when an assertion fails. The one exception is the marker used for the
`--tmpfs-home` non-persistence check: it is left for the second run to look
for, and the second run removes it if it is still there. It never runs your
command.

## Flags and the systemd directives behind them

| Flag | systemd directive | What it does |
|---|---|---|
| (always on) | `ProtectSystem=strict` | The whole filesystem is read-only except `/dev`, `/proc`, `/sys` and what you allow. |
| (always on) | `ProtectHome=read-only` | Home directories stay readable and become unwritable. |
| (always on) | `InaccessiblePaths=` on `$XDG_RUNTIME_DIR/bus` and `.../systemd` | Puts the service manager out of reach. See "The escape this closes" below. `--allow-user-bus` turns it off. |
| `--rw PATH` | `ReadWritePaths=` | Carves a writable exception out of the two above. Repeatable. `--rw /` and `--rw $HOME` are refused. |
| `--ro PATH` | `ReadOnlyPaths=` | Forces a path read-only, including inside a `--rw` tree. Repeatable. |
| `--hide PATH` | `InaccessiblePaths=` | Replaces the path with an empty node with mode 000: the contents are unreachable, reads return `EACCES` or `ENOENT`. Repeatable. |
| `--tmpfs-home` | `TemporaryFileSystem=$HOME:mode=0700` plus `BindPaths=` / `BindReadOnlyPaths=` | Replaces `$HOME` with an empty private tmpfs and binds the `--rw` and `--ro` paths that live under it back into place. |
| `--strict` | `NoNewPrivileges=yes`, `ProtectKernelTunables=yes`, `RestrictSUIDSGID=yes`, `ProtectProc=invisible`, `TemporaryFileSystem=$XDG_RUNTIME_DIR:mode=0700` | Hardening that costs something, so it is opt-in: no privilege gain through setuid, no kernel tunables, no setuid bits, and an empty runtime directory, which removes the agent sockets described below. `ProtectProc=` is in the list for completeness and has no effect on user units; the probe measures the result rather than trusting the directive. |
| `--max-runtime SPEC` | `RuntimeMaxSec=` | Wall clock. systemd kills the unit when it expires. Default `6h`; `infinity` disables it and the probe reports it as skipped. |
| `--env KEY=VALUE` | `--setenv` on the unit | Sets one variable in the run. Repeatable. |
| (default on) | `PrivateTmp=yes` | The run gets its own empty `/tmp` and `/var/tmp`, discarded at exit. `--no-private-tmp` shares the host `/tmp` instead. |
| `--cwd DIR` | `--working-directory` | Where the command starts. |
| `--unit-name NAME` | unit name | Default is `agent-sandbox-<cwd>-<timestamp>-<pid>`. A trailing `.service` is stripped; another unit suffix is refused. |
| `--property K=V` | any directive, verbatim | Escape hatch for directives this tool does not wrap, for example `MemoryMax=`, `CPUQuota=`, `PrivateNetwork=yes`. Repeatable. |

Every path is made absolute and normalized before it is used, so `..` and `.`
components collapse and the printed command line shows the paths systemd will
actually mount. A leading `-` on a `--rw`, `--ro` or `--hide` path is systemd's
tolerate-missing marker: the launcher skips its existence check and systemd
ignores the path if it is not there. The probe reports such a path as skipped
rather than passed.

`--dry-run` prints the assembled `systemd-run` command line on stdout (the
header goes to stderr, so redirecting stdout gives you a line you can paste
into a shell). `--probe` and `--dry-run` combine.

## The escape this closes

A confined process that can reach `$XDG_RUNTIME_DIR/bus` or
`$XDG_RUNTIME_DIR/systemd` can ask the user service manager for a second,
unconfined unit, and that unit can write anywhere you can write and read every
path you hid. `systemd-run` is in this tool's own requirements, so the means is
always present. One line was enough:

```sh
agent-sandbox --cwd ~/work --rw ~/work --hide ~/.ssh -- \
  bash -c "systemd-run --user --pipe -- bash -c 'cat ~/.ssh/id_ed25519'"
```

So the two sockets are hidden by default, the probe asserts that they are
unreachable, and it also tries to start a unit from inside and fails the run if
that succeeds. If your run legitimately drives systemd, `--allow-user-bus`
restores the access and the probe reports the wall as skipped, in those words.

## Profiles

A profile is a plain `KEY=value` file that bash sources, so one scheduled lane
is one file and one flag. Flags override a profile's single values and add to
its lists.

```sh
CWD="$HOME/work/project"
RW="$HOME/work/project $HOME/.cache/my-agent"
RO="$HOME/work/project/docs/law"
HIDE="$HOME/.ssh $HOME/.config/secret-cli"
MAX_RUNTIME=2h
SETENV="AGENT_MODE=batch"
COMMAND=( my-agent --nightly )
```

```sh
./agent-sandbox --profile ~/lanes/nightly.profile --probe
./agent-sandbox --profile ~/lanes/nightly.profile
```

Keys: `CWD`, `RW`, `RO`, `HIDE`, `TMPFS_HOME` (0 or 1), `PRIVATE_TMP` (0 or 1),
`STRICT` (0 or 1), `ALLOW_USER_BUS` (0 or 1), `MAX_RUNTIME`, `SETENV`,
`PROPERTIES`, `UNIT_NAME`, `COMMAND`.

List keys take either a whitespace separated string or a bash array. Use the
array form for `COMMAND` and for any path with a space in it: a string is split
on whitespace and nothing else, so `COMMAND="my-agent -p 'work the queue'"`
becomes five arguments with the quote characters still attached. The launcher
refuses a string `COMMAND` that contains a quote character for that reason.
Because the file is sourced, it can run code, so treat it as your own
configuration and not as untrusted input. See `examples/claude-code.profile`.

## The credential directory pattern

`ProtectHome=read-only` stops writes, and leaves everything in your home
readable. For an agent that talks to the network, reading is the interesting
half: tokens, ssh keys, cloud credentials, password stores. So hide what the
run does not need, and allow only what it does:

```sh
--hide ~/.ssh \
--hide ~/.aws \
--hide ~/.config/gh \
--hide ~/.config/secret-cli \
--rw   ~/.cache/my-agent
```

`--hide` is per path, so it is a list you have to maintain as you install new
tools. If you want the opposite default, `--tmpfs-home` hides everything in
`$HOME` at once and you bind back only what the run needs. It is the stricter
posture and the one that breaks tools that expect their config to exist, so
probe it before you schedule it.

**Hiding a credential directory does not disconnect the agent process that
already holds those credentials.** `--hide ~/.gnupg` removes the key files and
leaves `/run/user/<uid>/gnupg/S.gpg-agent`, which will still sign. The same
goes for `~/.ssh` and a running `ssh-agent` at `$SSH_AUTH_SOCK`, and for the
login keyring at `/run/user/<uid>/keyring/*`, which speaks the secret-service
protocol and holds stored passwords. Run the probe and read its list of visible
sockets: that is the exact set your run can talk to. `--strict` puts an empty
tmpfs over the whole runtime directory and removes all of them, at the cost of
whatever else in your setup uses those sockets.

Some tools do not read `$HOME`. They resolve the home directory through the
passwd database (`getpwuid`), which means `HOME=/somewhere/else` in the
environment moves nothing. `--tmpfs-home` is the answer to those: the real home
is not in the namespace at all, and the path the tool insists on writing to is
an empty tmpfs that goes away when the run ends.

## Things that surprise people

- **The unit does not inherit your shell's environment.** It gets the
  environment of your user service manager, which usually means a short `PATH`
  such as `/usr/local/bin:/usr/bin`. If your agent lives in `~/.local/bin` or a
  version manager's directory, give an absolute path or set `--env PATH=...`.
  Anything else the run needs, pass with `--env`.
- **systemd substitutes `${VARIABLE}` in a unit's command line** before the
  process starts, and an unknown name becomes empty. A prompt containing
  `${...}` would arrive mangled, so `agent-sandbox` doubles every `$` in your
  command, which is systemd's escape for a literal one. What you typed is what
  runs. `--dry-run` shows the escaped form. `%` is not touched by systemd here
  and is not escaped.
- **A private `/tmp` and paths under `/tmp` do not mix.** With `PrivateTmp=yes`
  the unit has its own empty `/tmp`, so a `--cwd`, `--rw`, `--ro` or `--hide`
  path under `/tmp` is not in the namespace and the unit would fail to start.
  The launcher refuses that combination and tells you to pass
  `--no-private-tmp`; it will not drop the private `/tmp` silently.
- **A hidden path still has a name.** `InaccessiblePaths=` leaves an empty
  directory entry with mode 000 in place. `ls -d` on it works; reading through
  it does not.
- **Under `--tmpfs-home`, home paths change directive.** A `--rw` path under
  `$HOME` is mounted with `BindPaths=` rather than `ReadWritePaths=`, because
  the tmpfs has already covered the real path and `ReadWritePaths=` on a path
  that is not in the namespace fails the unit with status `226/NAMESPACE`. A
  `--hide` path under `$HOME` is passed with systemd's tolerate-missing prefix
  for the same reason: the tmpfs removed it already.
- **The exit status does not say why a run ended.** An ordinary exit is passed
  through unchanged, but a segfault, a missing binary and a wall-clock kill all
  arrive as 1. If a scheduler has to tell them apart, pass `--unit-name` and
  read `journalctl --user -u <name>` afterwards. `systemctl show` will not help
  after the fact: the unit is started with `--collect`, so it is gone once it
  exits, and `systemctl show` answers for a missing unit with property defaults
  rather than an error.
- **A wrong `XDG_RUNTIME_DIR` is not a wall.** The launcher hides the manager
  sockets at the path that variable names, while the unit inherits the
  manager's own runtime directory. If the variable points somewhere that does
  not exist, the launcher warns on stderr and the probe reports the socket
  checks as skipped and then fails on its attempt to start a unit, because
  absent is not the same as blocked.
- **Failures show up in the journal.** `journalctl --user -u <unit-name>`.
  `226/NAMESPACE` means a path in one of the mount directives did not exist
  inside the namespace.

## What this does not protect against

- **The network.** The run can reach anything your user can reach. That is
  usually the point, since the agent needs its API. `--property
  PrivateNetwork=yes` exists if you want to cut it off, and will stop most
  agents from working at all.
- **Credentials the run legitimately holds.** Anything you pass with `--env` or
  leave readable in an allowed path is available to the agent and to whatever it
  is persuaded to do with it.
- **Live agents that hold your credentials.** See the credential directory
  section: hiding a directory does not close the socket of a process that has
  already unlocked it. `--strict` closes the ones under the runtime directory.
- **Other processes of the same user.** They stay visible in `/proc` and, at
  `ptrace_scope=0`, attachable. `ProtectProc=` and `ProcSubset=` are system
  service directives and do nothing for a user unit; the probe measures what is
  actually visible instead of claiming otherwise.
- **Damage inside the allowlist.** Everything you make writable can be
  rewritten or deleted. Keep the allowlist small, and keep it under version
  control or a backup.
- **Reading the rest of the machine.** `ProtectSystem=strict` is about writes.
  Source code, documents and configuration elsewhere stay readable unless you
  hide them.
- **Kernel and systemd bugs.** These are kernel namespaces. A namespace escape
  or a systemd bug is out of scope for a shell script.
- **Resource exhaustion.** The wall clock bounds time, not memory, CPU or disk.
  systemd has `MemoryMax=`, `CPUQuota=` and `TasksMax=` if you want them, via
  `--property`.
- **Anything at all if you skip the probe.** A sandbox nobody tested is a
  belief.

## Scheduling

`agent-sandbox` creates no timers and installs nothing. To schedule a run, call
it from a systemd timer, a cron line, or whatever you already use.
`examples/nightly.service` and `examples/nightly.timer` show the timer shape,
including running `--probe` first so a broken sandbox stops the run instead of
loosening it.

## Tests

```sh
test/run.sh
```

The offline part covers argument handling, path normalization and `--dry-run`
output. The live part runs the real `--probe` three times (plain,
`--tmpfs-home`, `--strict`), runs the delegated-unit escape twice (once with
`--allow-user-bus`, where it must land, and once without, where it must not),
checks that a probe whose payload cannot run reports that instead of passing, runs a real command to confirm it can write inside the allowlist and not
outside, and checks that the wall clock kills an overrunning run. It uses a
scratch directory (`mktemp -d`, or `$AGENT_SANDBOX_TEST_DIR` if you set one)
and writes nowhere else. Without a systemd user manager the live part is
skipped and prints the command to run by hand.

If you have shellcheck, `shellcheck agent-sandbox test/run.sh` is a reasonable
extra gate before sending a patch.

## License

Apache-2.0. Copyright 2026 Archbotics Oy. See `LICENSE`.
