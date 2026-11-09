# Caveats

**Platforms.** Linux and macOS. CI runs the installer, the restores and the process lookups on
both. Two things are verified on Linux only: the round trips with the real agents, and the
moment of shutdown itself. On macOS, CI triggers the shutdown watcher's save by hand, because
it can't log out. The watcher needs the Xcode Command Line Tools, which Homebrew installs.
Without them, the installer says so and the minute-by-minute save still runs.

**Power loss and crashes** lose up to a minute: whatever happened since the last save.

**Scrollback is saved to disk.** To bring scrollback back, tmux-resurrect saves every pane's
contents every minute, in its save folder (usually `~/.local/share/tmux/resurrect`).
tmux-restore makes that folder readable only by you. Whatever a pane showed goes in, a password
or token included. To stop saving it, add `set -g @resurrect-capture-pane-contents 'off'` to
your tmux config, then delete `pane_contents.tar.gz` from that folder.

**Programs restart; they aren't checkpointed.** An agent gets its conversation back, not a tool
call or command it was running at the time.

**Agent session files are internal.** Adapters read files the agents don't document. If an agent
changes them, its panes fall back to "continue the latest conversation in this directory", or to
a pre-typed command.

**Pre-typed commands need zsh.** With another shell, a command that isn't safe to re-run comes
back as an empty prompt.

**Python venvs come back only with zsh or bash,** and only once you add
[one line](how-it-works.md#python-virtual-environments) to `~/.zshrc` or `~/.bashrc`. A pane
running a program that tmux-resurrect restarts itself (vim, htop, ...) comes back without its
venv; so does a pane with bash whose command isn't safe to re-run. conda environments aren't
restored.

**Same agent, same directory.** Gemini CLI, opencode and pi don't record which process has which
conversation open, so tmux-restore tells their panes apart by directory and start time. Two panes
running the same one of them in the same directory come back as commands typed on the prompt,
rather than both opening the same conversation. Claude Code and Codex are always exact.

**Gemini CLI before 0.47** has a bug: a session resumed twice with nothing typed in between comes
back empty (the conversation is still on disk). Update Gemini CLI.

**Agents' own prompts still show.** Codex asks about updates on start, for example; a restored
pane waits at that prompt like a fresh start would.

**The tmux-resurrect fork.** Until
[tmux-resurrect#600](https://github.com/tmux-plugins/tmux-resurrect/pull/600) is merged, the
installer points tmux-resurrect at a fork with the concurrent-restore fix. If your
tmux-resurrect checkout has local changes, the installer leaves it alone and you don't get the fix.

**Nobody attached, nobody logged in.** The minute-by-minute save runs from tmux's status line,
which tmux draws only for an attached client, so a detached tmux is saved only at shutdown. That
save runs in your systemd user manager, which stops with your last login session unless your user
lingers. The installer enables lingering (`loginctl enable-linger`), and tells you the `sudo`
command if it can't. `--uninstall` turns it off again if the installer turned it on.

**Saving at shutdown has a time limit.** logind waits for the save up to `InhibitDelayMaxSec`:
5 s by default, 30 s on Ubuntu with unattended-upgrades. A save with 40 panes and long scrollback
takes about 4 s. To check yours, run
`time ~/.tmux/plugins/tmux-resurrect/scripts/save.sh quiet`. To raise the limit (it takes effect
after a reboot):

```sh
sudo mkdir -p /etc/systemd/logind.conf.d
printf '[Login]\nInhibitDelayMaxSec=30\n' | sudo tee /etc/systemd/logind.conf.d/tmux-restore.conf
```

**Your tmux config gets a block** between `# >>> tmux-restore >>>` and `# <<< tmux-restore <<<`.
The installer keeps your original as `tmux.conf.before-tmux-restore`. To undo everything:

```sh
curl -fsSL https://raw.githubusercontent.com/andrewboldi/tmux-restore/main/install.sh | bash -s -- --uninstall
```

**Manual install**, without the installer: add these above TPM's `run` line, press prefix + I,
then enable the service with
`systemctl --user enable --now ~/.tmux/plugins/tmux-restore/systemd/tmux-restore.service`.

```tmux
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'andrewboldi/tmux-resurrect#fix-concurrent-restore'
set -g @plugin 'andrewboldi/tmux-restore'
set -g @plugin 'tmux-plugins/tmux-continuum'   # last: it skips restoring while other plugins load
set -g @continuum-restore 'on'
```
