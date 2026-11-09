# Install by hand

These are the steps [`install.sh`](../install.sh) runs, for when you'd rather run them yourself.
To use the script but read it first:

```sh
curl -fsSL https://raw.githubusercontent.com/andrewboldi/tmux-restore/main/install.sh -o install.sh
less install.sh
bash install.sh
```

## 1. Packages

```sh
sudo apt install tmux git jq sqlite3 libglib2.0-bin   # Debian, Ubuntu
sudo dnf install tmux git jq sqlite glib2             # Fedora
sudo pacman -S --needed tmux git jq sqlite glib2      # Arch
brew install tmux jq bash flock                       # macOS
```

| Package | Used for |
|---|---|
| tmux, git | tmux itself; TPM installs plugins with git |
| jq | reading Claude Code's, Codex's and Gemini CLI's session files |
| sqlite3 | reading opencode's sessions |
| gdbus (`libglib2.0-bin`, `glib2`) | hearing that Linux is about to shut down, to save first |
| bash 4 or newer (macOS) | the save hook; macOS ships bash 3.2 |
| flock | letting only one restore run at a time; on Linux it comes with util-linux |

On macOS, git and the Swift compiler for step 3 come with the Command Line Tools
(`xcode-select --install`).

## 2. Plugins

Install [TPM](https://github.com/tmux-plugins/tpm):

```sh
git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
```

Add these lines to `~/.tmux.conf`. The `run` line stays at the very bottom:

```tmux
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'andrewboldi/tmux-resurrect#fix-concurrent-restore'
set -g @plugin 'andrewboldi/tmux-restore'
set -g @plugin 'tmux-plugins/tmux-continuum'
set -g @continuum-restore 'on'

run '~/.tmux/plugins/tpm/tpm'
```

Then install the plugins: press prefix + I (capital i) in tmux, or run
`~/.tmux/plugins/tpm/bin/install_plugins` and start tmux.

- **Already using tmux-resurrect or tmux-continuum?** Remove your own `@plugin` lines for them;
  the lines above replace them. The tmux-resurrect line is a fork with a fix for two restores
  running at once ([proposed upstream](https://github.com/tmux-plugins/tmux-resurrect/pull/600));
  `tmux-plugins/tmux-resurrect` works too, without that fix. TPM keeps a plugin folder that's
  already there, so delete `~/.tmux/plugins/tmux-resurrect` before installing. Your saves are
  kept elsewhere and stay.
- **tmux-continuum goes last.** It skips restoring if it sees other tmux commands still running,
  such as a plugin that loads after it.
- **`@continuum-restore` goes in the config file.** tmux-continuum reads it as soon as it loads.
- **Config in `~/.config/tmux/tmux.conf`?** Then TPM keeps plugins in `~/.config/tmux/plugins`;
  use that wherever this page says `~/.tmux/plugins`.

tmux-restore turns on a few options of tmux-resurrect and tmux-continuum unless you set them
yourself: a save every minute, saving pane contents, and on Linux reading commands from `/proc`.

## 3. Save at shutdown

The save every minute already works. This adds one more save just before the machine shuts down.

**Linux with systemd:**

```sh
mkdir -p ~/.config/systemd/user
cp ~/.tmux/plugins/tmux-restore/systemd/tmux-restore.service ~/.config/systemd/user/
systemctl --user enable --now tmux-restore.service
```

If your plugins aren't in `~/.tmux/plugins`, fix the `ExecStart=` path in the copied file.

If you leave tmux running when you log out, as on a server you reach over SSH, also run
`loginctl enable-linger`. tmux only runs the save every minute while a client is attached, and
without lingering the service stops when you log out.

**macOS:**

```sh
d=~/.tmux/plugins/tmux-restore
mkdir -p "$d/bin" ~/Library/LaunchAgents
swiftc -O -o "$d/bin/tmux-restore-shutdown" "$d/scripts/shutdown-watcher.swift"
cat > ~/Library/LaunchAgents/io.github.andrewboldi.tmux-restore.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>io.github.andrewboldi.tmux-restore</string>
	<key>ProgramArguments</key>
	<array><string>$d/bin/tmux-restore-shutdown</string><string>$d/scripts/save-now.sh</string></array>
	<key>EnvironmentVariables</key>
	<dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string><key>LANG</key><string>en_US.UTF-8</string></dict>
	<key>StandardOutPath</key><string>$HOME/Library/Logs/tmux-restore.log</string>
	<key>StandardErrorPath</key><string>$HOME/Library/Logs/tmux-restore.log</string>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
EOF
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/io.github.andrewboldi.tmux-restore.plist
```

The watcher saves when macOS announces a logout, restart or shutdown. The `LANG` line matters:
without a UTF-8 locale, the saves come out empty.

## 4. Python venvs

To have each pane's active venv come back, add this line to `~/.zshrc` or `~/.bashrc`:

```sh
[ -r ~/.tmux/plugins/tmux-restore/scripts/shell-hook.sh ] && . ~/.tmux/plugins/tmux-restore/scripts/shell-hook.sh
```

## 5. Try it

Save with prefix + Ctrl-s, run `tmux kill-server`, then start tmux again.

## Uninstall

- Remove the lines from `~/.tmux.conf` (and the venv line from `~/.zshrc` or `~/.bashrc`), and
  delete `~/.tmux/plugins/tmux-restore`.
- Linux: `systemctl --user disable --now tmux-restore.service`, then delete
  `~/.config/systemd/user/tmux-restore.service`. If you turned on lingering only for this,
  `loginctl disable-linger`.
- macOS: `launchctl bootout gui/$(id -u)/io.github.andrewboldi.tmux-restore`, then delete
  `~/Library/LaunchAgents/io.github.andrewboldi.tmux-restore.plist`.
