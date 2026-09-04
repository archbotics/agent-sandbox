#!/usr/bin/env bash
#
# test/run.sh - offline checks for argument handling and --dry-run output,
# then the real --probe if this machine has a systemd user manager.
#
# Copyright 2026 Archbotics Oy
# SPDX-License-Identifier: Apache-2.0
#
# Scratch directory: $AGENT_SANDBOX_TEST_DIR if set, otherwise a fresh mktemp
# directory. Nothing is written outside it. Paths under /tmp force
# --no-private-tmp in the live runs, which is itself one of the cases below.

set -uo pipefail

here=$(cd -- "$(dirname -- "$0")" && pwd)
root=$(cd -- "$here/.." && pwd)
sb="$root/agent-sandbox"

scratch=${AGENT_SANDBOX_TEST_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/agent-sandbox-test.XXXXXX")}
mkdir -p "$scratch/work" "$scratch/cache" "$scratch/law" "$scratch/secrets" "$scratch/fake-home"
printf 'rules\n' > "$scratch/law/RULES.md"
printf 'not-a-real-token\n' > "$scratch/secrets/token"

cat > "$scratch/quoted.profile" <<'QP'
COMMAND="my-agent -p 'work the queue'"
QP

pass=0
fail=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
no()   { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ $# -lt 2 ] || printf '     %s\n' "$2"; }

# expect_out NAME PATTERN -- cmd...   : command succeeds and prints PATTERN
expect_out() {
  local name=$1 pat=$2 out rc
  shift 3
  out=$("$@" 2>&1); rc=$?
  if [ $rc -ne 0 ]; then no "$name" "exit $rc: $out"; return; fi
  case $out in *"$pat"*) ok "$name" ;; *) no "$name" "no match for [$pat] in: $out" ;; esac
}

# expect_no_out NAME PATTERN -- cmd... : command succeeds and does NOT print PATTERN
expect_no_out() {
  local name=$1 pat=$2 out rc
  shift 3
  out=$("$@" 2>&1); rc=$?
  if [ $rc -ne 0 ]; then no "$name" "exit $rc: $out"; return; fi
  case $out in *"$pat"*) no "$name" "unexpected [$pat] in: $out" ;; *) ok "$name" ;; esac
}

# expect_fail NAME PATTERN -- cmd...  : command fails and explains itself
expect_fail() {
  local name=$1 pat=$2 out rc
  shift 3
  out=$("$@" 2>&1); rc=$?
  if [ $rc -eq 0 ]; then no "$name" "expected a nonzero exit, got 0: $out"; return; fi
  case $out in *"$pat"*) ok "$name" ;; *) no "$name" "no match for [$pat] in: $out" ;; esac
}

echo "# offline: usage and argument handling"
expect_out "--help prints usage" "usage: agent-sandbox" -- "$sb" --help
expect_out "--version prints a version" "agent-sandbox 0." -- "$sb" --version
expect_fail "a command is required" "no command" -- "$sb" --cwd "$scratch/work"
expect_fail "unknown options are refused" "unknown option" -- "$sb" --nope -- true
expect_fail "a bare argument is refused" "the command goes after" -- "$sb" true
expect_fail "--rw needs an existing path" "does not exist" -- "$sb" --rw "$scratch/nope" --dry-run -- true
expect_fail "--cwd needs a directory" "not a directory" -- "$sb" --cwd "$scratch/law/RULES.md" --dry-run -- true
expect_fail "--env wants KEY=VALUE" "expects KEY=VALUE" -- "$sb" --env NOTANASSIGNMENT --dry-run -- true
expect_fail "--unit-name is checked" "may only use letters" -- "$sb" --unit-name "bad name/slash" --dry-run -- true
expect_fail "/tmp paths clash with a private /tmp" "private /tmp" \
  -- "$sb" --cwd "$root" --rw /tmp --dry-run -- true
expect_fail "the private /tmp guard survives a non-normalized path" "private /tmp" \
  -- "$sb" --cwd "$root" --rw /home/../tmp --dry-run -- true

expect_fail "--rw / is refused" "opposite of this tool" -- "$sb" --cwd "$root" --rw / --dry-run -- true
expect_fail "--rw \$HOME is refused" "entire home writable" \
  -- env HOME="$scratch/fake-home" "$sb" --cwd "$scratch/fake-home" --rw "$scratch/fake-home" \
       --no-private-tmp --dry-run -- true
expect_fail "--rw \$HOME with a trailing /. is refused too" "entire home writable" \
  -- env HOME="$scratch/fake-home" "$sb" --cwd "$scratch/fake-home" --rw "$scratch/fake-home/." \
       --no-private-tmp --dry-run -- true
expect_fail "a unit name with a non-service suffix is refused" "plain name or end in .service" \
  -- "$sb" --cwd "$root" --unit-name lane.timer --dry-run -- true
expect_fail "a profile COMMAND string with quotes is refused" "use the array form" \
  -- "$sb" --profile "$scratch/quoted.profile" --dry-run

echo "# offline: --dry-run renders the systemd-run line"
dry=$("$sb" --cwd "$scratch/work" --rw "$scratch/work" --rw "$scratch/cache" \
        --ro "$scratch/law" --hide "$scratch/secrets" --no-private-tmp \
        --env FOO=bar --unit-name dryrun-demo --dry-run -- echo hello 2>/dev/null)
for want in \
  "systemd-run --user --pipe --collect" \
  "--unit=dryrun-demo" \
  "--property=ProtectSystem=strict" \
  "--property=ProtectHome=read-only" \
  "--property=ReadWritePaths=$scratch/work" \
  "--property=ReadWritePaths=$scratch/cache" \
  "--property=ReadOnlyPaths=$scratch/law" \
  "--property=InaccessiblePaths=$scratch/secrets" \
  "--property=RuntimeMaxSec=6h" \
  "--setenv=FOO=bar" \
  "-- echo hello"
do
  case $dry in *"$want"*) ok "dry-run has $want" ;; *) no "dry-run has $want" "$dry" ;; esac
done
case $dry in *PrivateTmp*) no "--no-private-tmp drops PrivateTmp" "$dry" ;; *) ok "--no-private-tmp drops PrivateTmp" ;; esac

expect_out "PrivateTmp=yes is the default" "--property=PrivateTmp=yes" \
  -- "$sb" --cwd "$root" --dry-run -- true
expect_no_out "--max-runtime infinity drops the wall clock" "RuntimeMaxSec" \
  -- "$sb" --cwd "$scratch/fake-home" --no-private-tmp --max-runtime infinity --dry-run -- true
expect_out "a dollar sign in the command is escaped for systemd" 'echo \$\$\{HOME\}' \
  -- "$sb" --cwd "$scratch/fake-home" --no-private-tmp --dry-run -- echo '${HOME}'

mkdir -p "$scratch/with space"
expect_out "a path with a space is quoted for systemd" 'ReadWritePaths=\"' \
  -- "$sb" --cwd "$scratch/fake-home" --rw "$scratch/with space" --no-private-tmp --dry-run -- true

expect_out "paths are normalized before they reach systemd" "--property=ReadWritePaths=$scratch/work " \
  -- "$sb" --cwd "$root" --rw "$scratch/cache/../work" --no-private-tmp --dry-run -- true
expect_no_out "--allow-user-bus drops the socket walls" "InaccessiblePaths=-" \
  -- "$sb" --cwd "$root" --allow-user-bus --dry-run -- true
strict=$("$sb" --cwd "$root" --strict --dry-run -- true 2>/dev/null)
for want in \
  "--property=NoNewPrivileges=yes" \
  "--property=ProtectKernelTunables=yes" \
  "--property=RestrictSUIDSGID=yes" \
  "--property=TemporaryFileSystem=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}:mode=0700"
do
  case $strict in *"$want"*) ok "--strict adds $want" ;; *) no "--strict adds $want" "$strict" ;; esac
done

echo "# offline: --tmpfs-home rewrites home paths as bind mounts"
# HOME is pointed at a scratch directory so the test never depends on, or
# touches, the real home.
mkdir -p "$scratch/fake-home/project" "$scratch/fake-home/.config/secret-cli"
tm=$(HOME="$scratch/fake-home" "$sb" --cwd "$scratch/fake-home/project" \
      --rw "$scratch/fake-home/project" --ro "$scratch/law" \
      --hide "$scratch/fake-home/.config/secret-cli" \
      --tmpfs-home --no-private-tmp --dry-run -- true 2>/dev/null)
for want in \
  "--property=TemporaryFileSystem=$scratch/fake-home:mode=0700" \
  "--property=BindPaths=$scratch/fake-home/project" \
  "--property=ReadOnlyPaths=$scratch/law" \
  "--property=InaccessiblePaths=-$scratch/fake-home/.config/secret-cli"
do
  case $tm in *"$want"*) ok "tmpfs-home has $want" ;; *) no "tmpfs-home has $want" "$tm" ;; esac
done
case $tm in
  *"--property=ReadWritePaths=$scratch/fake-home/project"*)
    no "tmpfs-home uses BindPaths, not ReadWritePaths, under home" "$tm" ;;
  *) ok "tmpfs-home uses BindPaths, not ReadWritePaths, under home" ;;
esac
expect_fail "--tmpfs-home with --rw \$HOME is refused" "entire home writable" \
  -- env HOME="$scratch/fake-home" "$sb" --cwd "$scratch/fake-home" --rw "$scratch/fake-home" \
       --tmpfs-home --no-private-tmp --dry-run -- true

echo "# offline: profiles"
prof="$scratch/demo.profile"
cat > "$prof" <<PROFILE
CWD="$scratch/work"
RW="$scratch/work $scratch/cache"
RO="$scratch/law"
HIDE="$scratch/secrets"
PRIVATE_TMP=0
MAX_RUNTIME=45m
SETENV="A=1 B=2"
UNIT_NAME=from-profile
COMMAND=( echo from-profile )
PROFILE
pdry=$("$sb" --profile "$prof" --dry-run 2>/dev/null)
for want in \
  "--unit=from-profile" \
  "--working-directory=$scratch/work" \
  "--property=ReadWritePaths=$scratch/cache" \
  "--property=RuntimeMaxSec=45m" \
  "--setenv=A=1" "--setenv=B=2" \
  "-- echo from-profile"
do
  case $pdry in *"$want"*) ok "profile gives $want" ;; *) no "profile gives $want" "$pdry" ;; esac
done
pdry2=$("$sb" --profile "$prof" --max-runtime 5m --rw "$scratch/law" --dry-run -- true 2>/dev/null)
case $pdry2 in *"RuntimeMaxSec=5m"*) ok "a flag overrides a profile scalar" ;; *) no "a flag overrides a profile scalar" "$pdry2" ;; esac
case $pdry2 in
  *"ReadWritePaths=$scratch/work"*"ReadWritePaths=$scratch/law"*) ok "a flag adds to a profile list" ;;
  *) no "a flag adds to a profile list" "$pdry2" ;;
esac
case $pdry2 in *"-- true"*) ok "a command after -- beats the profile COMMAND" ;; *) no "a command after -- beats the profile COMMAND" "$pdry2" ;; esac

# array form of a list key
cat > "$scratch/array.profile" <<PROFILE
RW=( "$scratch/work" "$scratch/with space" )
PROFILE
expect_out "profile list keys accept a bash array" 'with\ space\"' \
  -- "$sb" --profile "$scratch/array.profile" --cwd "$scratch/fake-home" --no-private-tmp --dry-run -- true

echo "# offline: shipped examples"
if bash -n "$root/examples/claude-code.profile" 2>/dev/null; then
  ok "the example profile is valid bash"
else
  no "the example profile is valid bash"
fi
for f in examples/nightly.service examples/nightly.timer LICENSE README.md; do
  if [ -s "$root/$f" ]; then ok "$f is present"; else no "$f is present"; fi
done
expect_out "--property is passed through" "--property=NoNewPrivileges=yes" \
  -- "$sb" --cwd "$root" --property NoNewPrivileges=yes --dry-run -- true

echo "# live: systemd user manager"
if ! command -v systemd-run >/dev/null 2>&1 || ! systemctl --user show-environment >/dev/null 2>&1; then
  echo "skip live tests: no systemd-run or no user manager on this machine"
  echo "  to run them by hand once you have one:"
  echo "    $sb --cwd DIR --rw DIR --hide SECRETS --no-private-tmp --probe"
else
  echo "## probe: allowlist, denial, read-only, hidden, wall clock"
  if "$sb" --cwd "$scratch/work" --rw "$scratch/work" --rw "$scratch/cache" \
       --ro "$scratch/law" --hide "$scratch/secrets" --max-runtime 30m \
       --no-private-tmp --probe; then
    ok "--probe passes"
  else
    no "--probe passes"
  fi

  echo "## probe: private tmpfs home, two runs"
  if "$sb" --cwd "$scratch/work" --rw "$scratch/work" --hide "$scratch/secrets" \
       --tmpfs-home --max-runtime 10m --no-private-tmp --probe; then
    ok "--probe --tmpfs-home passes both phases"
  else
    no "--probe --tmpfs-home passes both phases"
  fi

  echo "## the confined run cannot ask the service manager to act for it"
  mkdir -p "$scratch/outside"
  # The escape one-liner, run twice. The negative control matters as much as the
  # assertion: if the delegated write stops landing for some unrelated reason
  # (no systemd-run inside the unit, a broken command line), the positive test
  # would pass vacuously and the headline wall would be untested.
  escape_cmd="systemd-run --user --collect --pipe --unit=agent-sandbox-test-escape-\$\$ -- bash -c 'echo ESCAPED > $scratch/outside/PWNED'"

  esc=$("$sb" --cwd "$scratch/work" --rw "$scratch/work" --no-private-tmp --max-runtime 1m \
          --allow-user-bus -- bash -c "$escape_cmd" 2>&1)
  if [ -e "$scratch/outside/PWNED" ]; then
    ok "control: with --allow-user-bus the delegated write does land"
    rm -f "$scratch/outside/PWNED"
  else
    no "control: with --allow-user-bus the delegated write does land" "$esc"
  fi

  esc=$("$sb" --cwd "$scratch/work" --rw "$scratch/work" --no-private-tmp --max-runtime 1m \
          -- bash -c "$escape_cmd" 2>&1)
  if [ -e "$scratch/outside/PWNED" ]; then
    no "a delegated unit cannot write outside the sandbox" "$esc"
    rm -f "$scratch/outside/PWNED"
  else
    ok "a delegated unit cannot write outside the sandbox"
  fi

  strictout=$("$sb" --cwd "$scratch/work" --rw "$scratch/work" --no-private-tmp --max-runtime 1m --strict --probe 2>&1)
  strictrc=$?
  if [ $strictrc -eq 0 ]; then ok "--probe --strict exits zero"; else no "--probe --strict exits zero" "$strictout"; fi
  for want in \
    "PASS: NoNewPrivileges is set" \
    "PASS: /proc/sys is read-only" \
    "PASS: setting a setuid bit is refused" \
    "PASS: nothing under" \
    "=== payload complete:"
  do
    case $strictout in *"$want"*) ok "--strict probe asserts $want" ;; *) no "--strict probe asserts $want" "$strictout" ;; esac
  done

  echo "## the probe refuses a verdict when its payload did not run"
  mkdir -p "$scratch/mut"
  sed 's/| base64 -d | bash"/| base64-absent -d | bash"/' "$sb" > "$scratch/mut/agent-sandbox"
  chmod +x "$scratch/mut/agent-sandbox"
  mutout=$("$scratch/mut/agent-sandbox" --cwd "$scratch/work" --rw "$scratch/work" \
             --no-private-tmp --max-runtime 1m --probe 2>&1)
  mutrc=$?
  case $mutout in
    *"did not run to completion"*) [ $mutrc -ne 0 ] && ok "a payload that cannot run is reported, not passed" ||
      no "a payload that cannot run is reported, not passed" "exit 0 with: $mutout" ;;
    *) no "a payload that cannot run is reported, not passed" "$mutout" ;;
  esac

  echo "## a real command sees the same walls"
  out=$("$sb" --cwd "$scratch/work" --rw "$scratch/work" --no-private-tmp --max-runtime 1m \
          -- bash -c 'echo written > ./inside.txt; echo blocked > '"$scratch"'/law/nope.txt 2>/dev/null && echo "WROTE-OUTSIDE" || echo "denied-outside"' 2>&1)
  case $out in *denied-outside*) ok "a real run cannot write outside the allowlist" ;; *) no "a real run cannot write outside the allowlist" "$out" ;; esac
  if [ -f "$scratch/work/inside.txt" ]; then ok "a real run writes inside the allowlist"; else no "a real run writes inside the allowlist"; fi
  rm -f "$scratch/work/inside.txt"

  echo "## the wall clock stops a run that overruns"
  start=$SECONDS
  "$sb" --cwd "$scratch/work" --no-private-tmp --max-runtime 2 -- sleep 30 >/dev/null 2>&1
  rc=$?
  if [ $rc -ne 0 ] && [ $((SECONDS - start)) -lt 20 ]; then
    ok "RuntimeMaxSec kills an overrunning run (exit $rc after $((SECONDS - start))s)"
  else
    no "RuntimeMaxSec kills an overrunning run" "exit $rc after $((SECONDS - start))s"
  fi
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
