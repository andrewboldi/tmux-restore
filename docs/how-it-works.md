# How it works

tmux-restore is a [TPM](https://github.com/tmux-plugins/tpm) plugin on top of
[tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) (saves and restores tmux) and
[tmux-continuum](https://github.com/tmux-plugins/tmux-continuum) (runs them automatically).

## Saving

Every minute, continuum runs resurrect's save. It records sessions, windows, pane layouts,
working directories and scrollback, plus each pane's full command line. Then resurrect calls
[`scripts/save-hook.sh`](../scripts/save-hook.sh), which rewrites each pane's saved command:

| The pane is running | Saved as | On restore |
|---|---|---|
| A coding agent | the agent's resume command, e.g. `claude --resume <id> --model opus` | the same conversation reopens, with the same flags |
| A safe program (vim, htop, less, ...) | unchanged | it restarts |
| Anything else (`make deploy`, a dev server) | `print -rz -- '<command>'` | the command is typed on the zsh prompt, waiting for Enter |

A safe program is one tmux-resurrect restarts by itself, by its own rules: one of its defaults,
or a match for an entry in your `@resurrect-processes`. An entry `"git log"` matches commands
that start with `git log`, and `"btop->btop --utf-force"` matches `btop`. A `"~pattern"` entry
counts only if it has a `->`; otherwise its commands come back typed.

The initial prompt and the flags that pick a conversation (`--continue`, `--resume`, ...) are
dropped from an agent's command. A rewritten command starts with `TMUX_RESTORE=1 `, and
tmux-restore adds that prefix to resurrect's list of programs to re-run. With a shell other than
zsh, "anything else" is left unchanged, so resurrect doesn't re-run it.

### Finding each agent's conversation

Each agent has a small adapter in [`agents/`](../agents). It recognizes the agent's process and
finds the id of the conversation that process has open, from the agent's own session files. See
[agents.md](agents.md) for what each one reads.

If the id can't be found, the adapter falls back to the agent's "continue the latest
conversation in this directory" command. If two panes would use that fallback in the same
directory, they'd both reopen the same conversation, so both get the pre-typed command instead.

## Saving at shutdown

On Linux with systemd, [`tmux-restore.service`](../systemd/tmux-restore.service) runs
[`scripts/shutdown-save.sh`](../scripts/shutdown-save.sh) under
`systemd-inhibit --mode=delay`. When the machine announces a shutdown or reboot (logind's
`PrepareForShutdown`), it saves, and logind waits for it.

On macOS, the installer builds [a small watcher](../scripts/shutdown-watcher.swift) and runs it
as a LaunchAgent. macOS announces a logout, restart or shutdown to running programs before apps
quit (`NSWorkspace.willPowerOffNotification`), and the watcher saves then. Its log is
`~/Library/Logs/tmux-restore.log`.

The minute-by-minute saves cover crashes and power loss.

## Restoring

When the tmux server starts, continuum runs resurrect's restore. Sessions, windows, layouts and
scrollback come back, then the saved commands run, including each agent's resume command.

### The concurrent-restore fix

tmux-resurrect restores a pane with "pane missing, window exists: split the window". If two
restores run at once, both split, and the extra panes get squashed to one line. Two restores
happen at login when something runs `tmux start-server` before the real server starts
(tmuxinator does): continuum on that first server queues a restore, the server exits, and the
restore lands on the real server, which has queued its own.

The installer therefore uses tmux-resurrect from
[a branch that allows one restore at a time](https://github.com/andrewboldi/tmux-resurrect/tree/fix-concurrent-restore),
proposed upstream as
[tmux-resurrect#600](https://github.com/tmux-plugins/tmux-resurrect/pull/600) (likely the cause of
[#437](https://github.com/tmux-plugins/tmux-resurrect/issues/437)).
[`tests/restore-race.sh`](../tests/restore-race.sh) restores a 29-window save twice at once:
upstream gets 2 to 6 windows wrong per run, the branch none.

## Options

tmux-restore sets these only if you haven't set them yourself:

| Option | Value |
|---|---|
| `@continuum-restore` | `on`: restore when the tmux server starts (the installer also writes it into your config, because continuum reads it before plugins listed after it load) |
| `@continuum-save-interval` | `1`: save every minute |
| `@resurrect-capture-pane-contents` | `on`: keep scrollback |
| `@resurrect-save-command-strategy` | `linux_procfs` on Linux: exact command lines |

It always sets two tmux-resurrect hooks, and a hook you already had there runs after its own:
`@resurrect-hook-post-save-layout` (the save hook) and `@resurrect-hook-pre-restore-all`, which
marks that a restore started. tmux-continuum skips its restore at startup if it counts other tmux
processes, and it can count the new server's own short-lived forks; if no restore has started
three seconds after the server did, tmux-restore runs it, under continuum's other conditions
([`scripts/restore-safety-net.sh`](../scripts/restore-safety-net.sh)).

## Files

| File | What it does |
|---|---|
| [`install.sh`](../install.sh) | installs everything and edits your tmux config (`--uninstall` undoes it) |
| [`tmux-restore.tmux`](../tmux-restore.tmux) | the plugin: sets the options above |
| [`scripts/save-hook.sh`](../scripts/save-hook.sh) | rewrites saved commands |
| [`scripts/lib.sh`](../scripts/lib.sh) | process inspection (`/proc`, or `ps`/`lsof`) and flag filtering |
| [`agents/*.sh`](../agents) | one adapter per agent |
| [`scripts/shutdown-save.sh`](../scripts/shutdown-save.sh) | the save at shutdown (Linux) |
| [`scripts/shutdown-watcher.swift`](../scripts/shutdown-watcher.swift) | the save at shutdown (macOS) |
