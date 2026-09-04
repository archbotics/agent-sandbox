# Example agent-sandbox profile: an unattended Claude Code run.
#
# Copyright 2026 Archbotics Oy
# SPDX-License-Identifier: Apache-2.0
#
# Claude Code is one example. The same shape works for any agent CLI: the
# launcher does not know or care which one it is running.
#
# Copy this next to your other lane files, edit the paths, then check it:
#   agent-sandbox --profile my.profile --probe
#   agent-sandbox --profile my.profile --dry-run
#
# The file is sourced by bash, so $HOME and command substitution work, and so
# does anything else bash can do. Keep it under your own control.

# Where the run starts.
CWD="$HOME/work/project"

# The only writable paths. Everything else on the machine is read-only.
# The second entry is the agent's own state directory: agents that keep
# history, sessions or caches need it writable or they fail at startup.
# $HOME itself is refused here, and so is /.
RW="$HOME/work/project $HOME/.claude"

# Writable above, but these stay read-only: the rules the run must not
# rewrite. A prose instruction not to touch them is a request. This is not.
RO="$HOME/work/project/docs/policy"

# Not readable at all. ProtectHome=read-only leaves the whole home readable,
# which is the half that matters for an agent with network access, so name
# every credential directory the run does not need.
#
# This hides the key files, not the agents holding the keys: a running
# gpg-agent or ssh-agent is reachable through its socket under
# $XDG_RUNTIME_DIR. STRICT=1 below removes those too.
HIDE="$HOME/.ssh $HOME/.aws $HOME/.config/gh $HOME/.gnupg"

# Wall clock. systemd kills the unit when it expires.
MAX_RUNTIME=3h

# 1 adds NoNewPrivileges, ProtectKernelTunables, RestrictSUIDSGID and an empty
# tmpfs over $XDG_RUNTIME_DIR (which removes every agent socket, including the
# ones your desktop session uses). Probe it before you schedule it.
STRICT=0

# The unit does not inherit your shell environment: it gets the user service
# manager's, whose PATH is usually /usr/local/bin:/usr/bin. Pass what the run
# needs, and give an absolute path in COMMAND if the CLI lives elsewhere.
SETENV="AGENT_RUN=nightly"

# The command, as an array. A string would be split on whitespace and nothing
# else, which turns a quoted prompt into several arguments with the quotes
# still attached. Everything here is an example, including the flags: consult
# your agent's own documentation for its unattended-run and permission modes.
COMMAND=(
  claude -p "Work the queue in docs/queue.md. If this prompt is all you can see, stop and do nothing."
  --permission-mode acceptEdits
)

# Notes
#
# 1. A one-shot prompt cannot ask you anything, so whatever permission mode you
#    pick, the kernel walls above are the real boundary. Pick the mode that
#    matches what you allowed with RW, not the one that feels safe.
# 2. If the agent writes somewhere you did not list, it gets EROFS or EACCES
#    and usually reports it as a tool error. That is the sandbox working. Add
#    the path to RW deliberately, or leave it denied.
# 3. TMPFS_HOME=1 hides the whole home and binds only RW and RO back. It is
#    stricter, and it breaks tools whose config then no longer exists.
# 4. The service manager's sockets are hidden by default, which is what stops
#    the run from asking systemd for a second, unconfined unit. ALLOW_USER_BUS=1
#    gives that access back; the probe then reports the wall as skipped.
