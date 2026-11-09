<p align="center">
  <img src="assets/logo.svg" alt="" width="132">
</p>

<h1 align="center">tmux-restore</h1>

<p align="center"><b>Reboot-proof tmux. Your coding agents pick up mid-conversation.</b></p>

<p align="center">
  <a href="https://github.com/andrewboldi/tmux-restore/actions/workflows/test.yml"><img alt="tests" src="https://img.shields.io/github/actions/workflow/status/andrewboldi/tmux-restore/test.yml?branch=main&label=tests&style=flat-square"></a>
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/github/license/andrewboldi/tmux-restore?style=flat-square"></a>
  <a href="https://github.com/tmux-plugins/tpm"><img alt="tmux plugin" src="https://img.shields.io/badge/tmux-plugin-1bb91f?style=flat-square&logo=tmux&logoColor=white"></a>
</p>

<p align="center">
  <a href="#what-it-adds-to-tmux-resurrect">What it adds</a> ·
  <a href="#install">Install</a> ·
  <a href="#how-it-works">How it works</a> ·
  <a href="docs/agents.md">Agents</a> ·
  <a href="docs/caveats.md">Caveats</a> ·
  <a href="CONTRIBUTING.md">Contributing</a>
</p>

Ever rebooted and lost a dozen tmux windows, along with the agent conversations running in them?
tmux-restore saves everything every minute and right before shutdown, and puts it back when tmux
starts. Panes running Claude Code, Codex, Gemini CLI, opencode or pi reopen the exact
conversation they were in.

<p align="center">
  <img src="assets/demo.gif" alt="A tmux window with Claude Code, vim and a dev server. tmux is killed and started again: the conversation, vim and the layout come back, and the dev server's command waits on the prompt." width="820">
</p>

## What it adds to tmux-resurrect

tmux-restore runs on top of [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) and
[tmux-continuum](https://github.com/tmux-plugins/tmux-continuum), which bring back sessions,
windows, splits, working directories and scrollback. It adds:

- **Agents resume mid-conversation.** Each pane reopens its own conversation, with the same
  flags. [Supported agents](docs/agents.md)
- **Saved at shutdown, not just on a timer.** Every minute (continuum's default is 15), plus once
  more as the machine goes down. A crash or power cut loses at most the last minute.
- **The rest comes back typed, not lost.** Editors, monitors and whatever you list in
  `@resurrect-processes` restart. With zsh, any other command (a deploy, a dev server) waits on
  the prompt for Enter, where tmux-resurrect alone leaves an empty shell.
- **Python venvs come back,** once you add
  [one line](docs/how-it-works.md#python-virtual-environments) to `~/.zshrc` or `~/.bashrc`.

Scrollback is saved to disk, so anything a pane showed, a password included, sits in a folder
only you can read. To not save it, add `set -g @resurrect-capture-pane-contents 'off'`.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/andrewboldi/tmux-restore/main/install.sh | bash
```

It installs whatever is missing (tmux, TPM, the plugins) and turns everything on. Run it again to
update. Rather not run a script? [Install by hand](docs/install-manually.md).

**Already using tmux-resurrect and tmux-continuum?** Keep them: your settings, your list of
programs to restart and your saves carry over. The installer switches tmux-resurrect to
[a fork](https://github.com/andrewboldi/tmux-resurrect/tree/fix-concurrent-restore) that lets only
one restore run at a time
([proposed upstream](https://github.com/tmux-plugins/tmux-resurrect/pull/600)).

## How it works

tmux-resurrect saves each pane and its command. For an agent's pane, a small adapter finds the
conversation's id in the agent's own session files and saves the command that resumes it instead.
A background service (systemd on Linux, launchd on macOS) makes the save at shutdown. More in
[how it works](docs/how-it-works.md).

Using another agent? An adapter is one short file. Send it in ([CONTRIBUTING.md](CONTRIBUTING.md)),
or keep it to yourself in `~/.config/tmux-restore/agents/`.

## License

MIT. Built on tmux-resurrect and tmux-continuum by Bruno Sutic and contributors.
