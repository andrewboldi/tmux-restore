# Contributing

Bug reports, fixes and new agent adapters are welcome. Open an issue or a pull request.

## Run the tests

```sh
tests/hook-unit.sh          # flag filtering, quoting, pre-typed commands (needs tmux, zsh, jq, sqlite3)
tests/agents-unit.sh        # every adapter against a fake /proc
tests/proc-live.sh          # the process helpers against real processes (/proc, or ps and lsof)
tests/shutdown-unit.sh      # the save at shutdown, with fake gdbus and tmux
tests/restore-race.sh       # two restores at once must restore a 29-window save exactly
tests/login-replay.sh       # a tmuxinator-style login must restore once
tests/restore-safety-net.sh # if continuum skips its restore by mistake, tmux-restore restores
tests/restore-lock-release.sh # a finished restore releases its lock
tests/install-containers.sh # the installer on fresh Ubuntu, Debian, Fedora and Arch (docker or podman)
```

They run on throwaway tmux servers (`tmux -L <name>`) and never touch your own sessions or saves.
CI runs them on Linux and macOS.
The restore tests use the plugins in `~/.tmux/plugins`; point them elsewhere with `PLUGINS_DIR=`.
`tests/install-test.sh` rewrites `~/.tmux.conf`, so it only runs where
`TMUX_RESTORE_SANDBOX=1` is set, inside the containers.

Scripts are bash 4 (except `install.sh`, which also runs on macOS's bash 3.2) and pass
`shellcheck -x -S warning`.

## Add an agent

An adapter is one file, `agents/<name>.sh`, defining three functions named after it. They get
the pid of a process running in a pane:

```bash
# shellcheck shell=bash
# Acme Agent (https://example.com/acme)

# <name>_match PID: succeed if PID is this agent.
acme_match() { [[ $(proc_name "$1") == acme ]]; }

# <name>_session PID: print the id of the conversation PID has open, or fail.
acme_session() {
	local file
	file=$(proc_open_files "$1" | grep -m1 "$HOME/.acme/sessions/.*\.json$") || return 1
	basename "$file" .json
}

# <name>_resume PID ID: print the command that reopens conversation ID.
acme_resume() {
	proc_args "$1" || return 1
	printf 'acme --resume %s%s' "$2" "$(keep_flags acme "${ARGV[@]}")"
}

# Optional. <name>_continue PID: print a command that reopens the latest conversation in PID's
# directory. Used when the id can't be found, and skipped when two panes would share it.
acme_continue() { printf 'acme --continue'; }

# Set this if <name>_session is exact, never a guess. Then two panes on one conversation both
# come back on it; for a guess they'd come back typed on the prompt instead.
acme_exact=1

# For keep_flags: flags that take a value, so a value isn't mistaken for the initial prompt,
# and flags that pick a conversation, which the resume command replaces.
acme_value_flags="--model --profile"
acme_drop_flags="--continue --resume"
```

Helpers from [`scripts/lib.sh`](scripts/lib.sh), which work on Linux and macOS:

| Helper | Gives |
|---|---|
| `proc_name PID` | the program's name; for `node /usr/bin/acme` that's `acme` |
| `proc_comm PID` | the executable's name, as in `ps -o comm` |
| `proc_args PID` | sets the array `ARGV` to the program's arguments |
| `proc_cwd PID` | the working directory |
| `proc_open_files PID` | the files it has open |
| `proc_start PID` | when it started |
| `proc_children PID`, `proc_descendants PID` | child pids |
| `keep_flags NAME ARG...` | the flags worth keeping, shell-quoted |
| `unique_line` | passes stdin through only if it's exactly one line |

Rules of thumb:
- **Never guess.** If the conversation can only be found by a heuristic (start times,
  directories), require a unique match (`unique_line`) or fail. A wrong conversation is worse
  than a fallback.
- **Fail quietly.** Return non-zero and print nothing when unsure. The hook then uses the
  fallback.
- **Test it.** Add a case to [`tests/agents-unit.sh`](tests/agents-unit.sh): `mkproc` builds
  fake processes and `openfile` fakes open files. Then check the whole loop once for real: start
  the agent in a pane, send one message, save (prefix + Ctrl-s), `tmux kill-server`, start tmux,
  and make sure the same conversation comes back.

## Keep an adapter to yourself

An adapter only you need doesn't have to come here. Put it in
`~/.config/tmux-restore/agents/<name>.sh`: files there are loaded after the built-in ones, and one
with the same name replaces the built-in.

If your agent only needs to be started again the way it was, with no conversation to look up, it
doesn't need an adapter. Add its name to tmux-resurrect's list of programs to run again:
`set -g @resurrect-processes 'my-agent'`.
