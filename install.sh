#!/usr/bin/env bash
# tmux-restore installer. Re-run it to update; it changes nothing that's already in place.
#
#   curl -fsSL https://raw.githubusercontent.com/andrewboldi/tmux-restore/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/andrewboldi/tmux-restore/main/install.sh | bash -s -- --uninstall
#
# 1. Installs what's missing: tmux, git, jq, sqlite3 (and gdbus on Linux with systemd).
# 2. Installs TPM, tmux-resurrect (with a fix for concurrent restores), tmux-continuum and
#    tmux-restore, and adds them to your tmux config (the original is kept as *.before-tmux-restore).
# 3. Saves right before shutdown: a systemd user service on Linux, a LaunchAgent on macOS.
# 4. Loads the plugins into your running tmux server, if there is one.
#
# TMUX_RESTORE_SOURCE overrides where tmux-restore is cloned from (a URL or a path ending in
# /tmux-restore); used for testing. Runs with macOS's bash 3.2: no bash 4 features here.
set -euo pipefail

RESTORE_URL=${TMUX_RESTORE_SOURCE:-https://github.com/andrewboldi/tmux-restore}
RESURRECT_URL=https://github.com/andrewboldi/tmux-resurrect
RESURRECT_BRANCH=fix-concurrent-restore
BEGIN="# >>> tmux-restore >>>"
END="# <<< tmux-restore <<<"
COMMENTED="#tmux-restore# "
UNIT=tmux-restore.service
LABEL=io.github.andrewboldi.tmux-restore

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() {
	printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
	exit 1
}
have() { command -v "$1" > /dev/null 2>&1; }
user_systemd() { [ "$(uname -s)" = Linux ] && have systemctl && systemctl --user show-environment > /dev/null 2>&1; }

as_root() {
	if [ "$(id -u)" -eq 0 ]; then
		"$@"
	elif have sudo; then
		sudo "$@"
	else
		die "installing packages needs root, and sudo isn't available: $*"
	fi
}

# pkg_name MANAGER TOOL: the package that provides TOOL
pkg_name() {
	case $1:$2 in
	apt:gdbus) echo libglib2.0-bin ;;
	dnf:gdbus | yum:gdbus | pacman:gdbus) echo glib2 ;;
	zypper:gdbus) echo glib2-tools ;;
	apk:gdbus) echo glib ;;
	apt:sqlite3 | zypper:sqlite3) echo sqlite3 ;;
	*:sqlite3) echo sqlite ;;
	brew:flock) echo flock ;;
	*:flock) echo util-linux ;;
	*) echo "$2" ;;
	esac
}

install_packages() {
	local pm="" tool
	local -a pkgs=()
	if [ "$(uname -s)" = Darwin ]; then
		have brew || die "please install Homebrew (https://brew.sh) or these tools yourself: $*"
		pm=brew
	elif have apt-get; then pm=apt
	elif have dnf; then pm=dnf
	elif have yum; then pm=yum
	elif have pacman; then pm=pacman
	elif have zypper; then pm=zypper
	elif have apk; then pm=apk
	else die "please install these with your package manager, then run this again: $*"; fi
	for tool in "$@"; do pkgs+=("$(pkg_name "$pm" "$tool")"); done
	say "Installing ${pkgs[*]}"
	case $pm in
	brew) brew install -q "${pkgs[@]}" ;;
	apt) as_root apt-get update -qq && as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" > /dev/null ;;
	dnf | yum) as_root "$pm" install -y -q "${pkgs[@]}" > /dev/null ;;
	pacman) as_root pacman -Sy --noconfirm --needed "${pkgs[@]}" > /dev/null ;;
	zypper) as_root zypper -n -q install "${pkgs[@]}" > /dev/null ;;
	apk) as_root apk add -q "${pkgs[@]}" ;;
	esac
}

install_deps() {
	local -a need=()
	local tool
	for tool in tmux git jq sqlite3; do have "$tool" || need+=("$tool"); done
	if user_systemd; then
		for tool in gdbus flock; do have "$tool" || need+=("$tool"); done
	fi
	if [ "$(uname -s)" = Darwin ]; then
		# The save hook needs bash 4 (macOS ships 3.2); flock lets only one restore run at a time.
		[ -x /opt/homebrew/bin/bash ] || [ -x /usr/local/bin/bash ] || need+=(bash)
		have flock || need+=(flock)
	fi
	if [ ${#need[@]} -gt 0 ]; then install_packages "${need[@]}"; fi
	for tool in tmux git; do have "$tool" || die "$tool is still missing"; done
}

# The tmux config TPM reads: the XDG one if it exists, else ~/.tmux.conf.
tmux_conf() {
	local xdg="${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf"
	if [ -f "$xdg" ]; then echo "$xdg"; else echo "$HOME/.tmux.conf"; fi
}

# Where TPM keeps plugins: TMUX_PLUGIN_MANAGER_PATH if the config sets it, else TPM's default.
plugins_dir() {
	local set
	set=$(sed -n 's/^[[:space:]]*set-environment[[:space:]].*TMUX_PLUGIN_MANAGER_PATH[[:space:]]*["'\'']\{0,1\}\([^"'\'']*\).*/\1/p' "$CONF" 2> /dev/null | tail -1)
	if [ -n "$set" ]; then
		set=${set/#\~/$HOME}
		echo "${set%/}"
	elif [ "$CONF" = "$HOME/.tmux.conf" ]; then
		echo "$HOME/.tmux/plugins"
	else
		echo "$(dirname "$CONF")/plugins"
	fi
}

# clone URL DIR [BRANCH]
clone() {
	if [ -n "${3:-}" ]; then
		git clone -q --depth 1 -b "$3" "$1" "$2"
	else
		git clone -q --depth 1 "$1" "$2"
	fi
}

# Put tmux-resurrect on the branch with the concurrent-restore fix, unless it has local changes.
use_resurrect_fork() {
	local dir=$PLUGINS/tmux-resurrect
	if ! [ -d "$dir" ]; then
		clone "$RESURRECT_URL" "$dir" "$RESURRECT_BRANCH"
		return
	fi
	if ! git -C "$dir" rev-parse --git-dir > /dev/null 2>&1; then
		warn "$dir isn't a git checkout; leaving it as is (no fix for concurrent restores)"
	elif [ -n "$(git -C "$dir" status --porcelain 2> /dev/null)" ]; then
		warn "$dir has local changes; leaving it as is (no fix for concurrent restores)"
	elif [ "$(git -C "$dir" remote get-url origin 2> /dev/null)" = "$RESURRECT_URL" ]; then
		git -C "$dir" pull -q --ff-only || warn "couldn't update $dir"
	else
		say "Switching tmux-resurrect to $RESURRECT_URL ($RESURRECT_BRANCH)"
		git -C "$dir" remote set-url origin "$RESURRECT_URL"
		git -C "$dir" config remote.origin.fetch "+refs/heads/$RESURRECT_BRANCH:refs/remotes/origin/$RESURRECT_BRANCH"
		git -C "$dir" fetch -q --depth 1 origin
		git -C "$dir" checkout -q -B "$RESURRECT_BRANCH" "origin/$RESURRECT_BRANCH"
	fi
}

install_plugins() {
	say "Installing plugins in $PLUGINS"
	mkdir -p "$PLUGINS"
	[ -x "$(tpm_path)" ] || clone https://github.com/tmux-plugins/tpm "$PLUGINS/tpm"
	use_resurrect_fork
	[ -d "$PLUGINS/tmux-continuum" ] || clone https://github.com/tmux-plugins/tmux-continuum "$PLUGINS/tmux-continuum"
	if [ -d "$PLUGINS/tmux-restore" ]; then
		git -C "$PLUGINS/tmux-restore" pull -q --ff-only || warn "couldn't update $PLUGINS/tmux-restore"
	else
		clone "$RESTORE_URL" "$PLUGINS/tmux-restore"
	fi
}

# same_file A B: A and B have the same contents (cmp isn't on minimal systems)
same_file() { [ "$(cat "$1"; echo .)" = "$(cat "$2"; echo .)" ]; }

# The config's line that runs TPM, if any.
tpm_run_line() { grep -E '^[[:space:]]*run(-shell)?[[:space:]].*tpm' "$CONF" 2> /dev/null | head -1 || true; }

# The TPM script the config runs, or where we install it.
tpm_path() {
	local tpm
	tpm=$(tpm_run_line | sed -E "s/^[[:space:]]*run(-shell)?[[:space:]]+(-b[[:space:]]+)?//; s/^['\"]//; s/['\"][[:space:]]*\$//")
	tpm=${tpm/#\~/$HOME}
	echo "${tpm:-$PLUGINS/tpm/tpm}"
}

# listed NAME FILE: FILE has an (uncommented) @plugin line for NAME, e.g. tmux-plugins/tpm
listed() { grep -Eq "^[[:space:]]*set(-option)?[[:space:]]+(-g[[:space:]]+)?@plugin[[:space:]]+[\"']$1[#\"']" "$2"; }

# The config without our block, with plain tmux-resurrect lines put back (stdin -> stdout).
strip_block() {
	awk -v b="$BEGIN" -v e="$END" -v c="$COMMENTED" '
		$0 == b { skip = 1; next }
		$0 == e { skip = 0; next }
		skip { next }
		index($0, c) == 1 { print substr($0, length(c) + 1); next }
		{ print }'
}

edit_conf() {
	local tmp block run home_plugins
	tmp=$(mktemp)
	mkdir -p "$(dirname "$CONF")"
	touch "$CONF"
	strip_block < "$CONF" > "$tmp"
	# Our block replaces your tmux-resurrect line (same directory, the fork has the fix) and your
	# tmux-continuum line (it has to load last: it skips restoring if it sees other tmux
	# commands running, such as a plugin loading after it).
	awk -v c="$COMMENTED" '
		/^[[:space:]]*set(-option)?[[:space:]]+(-g[[:space:]]+)?@plugin[[:space:]]+["'\'']tmux-plugins\/tmux-(resurrect|continuum)[#"'\'']/ { print c $0; next }
		{ print }' "$tmp" > "$tmp.2"
	mv "$tmp.2" "$tmp"

	home_plugins=${PLUGINS/#$HOME/\~}
	block="$BEGIN"$'\n'
	listed tmux-plugins/tpm "$tmp" || block+="set -g @plugin 'tmux-plugins/tpm'"$'\n'
	block+="set -g @plugin 'andrewboldi/tmux-resurrect#$RESURRECT_BRANCH'"$'\n'
	if [ -n "${TMUX_RESTORE_SOURCE:-}" ]; then
		block+="set -g @plugin '$RESTORE_URL'"$'\n'
	else
		block+="set -g @plugin 'andrewboldi/tmux-restore'"$'\n'
	fi
	block+="set -g @plugin 'tmux-plugins/tmux-continuum'"$'\n'
	# continuum checks this as soon as it loads, possibly before tmux-restore sets it
	grep -Eq '^[[:space:]]*set(-option)?[[:space:]]+(-g[[:space:]]+)?@continuum-restore[[:space:]]' "$tmp" ||
		block+="set -g @continuum-restore 'on'"$'\n'
	block+="$END"

	run=$(grep -nE '^[[:space:]]*run(-shell)?[[:space:]].*tpm' "$tmp" | head -1 | cut -d: -f1 || true)
	if [ -n "$run" ]; then
		{ awk -v n="$run" 'NR < n' "$tmp"; printf '%s\n' "$block"; tail -n +"$run" "$tmp"; } > "$tmp.2"
	else
		{ cat "$tmp"; [ -s "$tmp" ] && echo; printf '%s\n' "$block" "run '$home_plugins/tpm/tpm'"; } > "$tmp.2"
	fi
	mv "$tmp.2" "$tmp"

	if same_file "$tmp" "$CONF"; then
		rm -f "$tmp"
		return
	fi
	[ -s "$CONF" ] && ! [ -e "$CONF.before-tmux-restore" ] && cp "$CONF" "$CONF.before-tmux-restore"
	cat "$tmp" > "$CONF"
	rm -f "$tmp"
	say "Updated $CONF"
}

# macOS: a small watcher, run by launchd, saves when macOS announces a logout, restart or shutdown.
install_launch_agent() {
	local plist="$HOME/Library/LaunchAgents/$LABEL.plist" bin="$PLUGINS/tmux-restore/bin/tmux-restore-shutdown" path dir lang
	if ! have swiftc; then
		say "No Swift compiler (Xcode Command Line Tools): tmux is saved every minute, but not at shutdown"
		return 0
	fi
	mkdir -p "$(dirname "$bin")" "$(dirname "$plist")"
	if ! swiftc -O -o "$bin" "$PLUGINS/tmux-restore/scripts/shutdown-watcher.swift" 2> /dev/null; then
		warn "couldn't build the shutdown watcher; tmux is saved every minute, but not at shutdown"
		return 0
	fi
	# launchd's environment has no UTF-8 locale, and in the C locale tmux turns the tabs in
	# tmux-resurrect's output into "_", which leaves the save empty.
	lang=${LC_ALL:-${LANG:-}}
	case $lang in *[Uu][Tt][Ff]-8 | *[Uu][Tt][Ff]8) ;; *) lang=en_US.UTF-8 ;; esac
	path=/usr/bin:/bin:/usr/sbin:/sbin # launchd's default PATH lacks Homebrew
	for dir in /usr/local/bin /opt/homebrew/bin "$(dirname "$(command -v jq || echo /usr/bin/jq)")" "$(dirname "$(command -v tmux)")"; do
		case ":$path:" in *":$dir:"*) ;; *) path="$dir:$path" ;; esac
	done
	cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array><string>$bin</string><string>$PLUGINS/tmux-restore/scripts/save-now.sh</string></array>
	<key>EnvironmentVariables</key>
	<dict><key>PATH</key><string>$path</string><key>LANG</key><string>$lang</string></dict>
	<key>StandardOutPath</key><string>$HOME/Library/Logs/tmux-restore.log</string>
	<key>StandardErrorPath</key><string>$HOME/Library/Logs/tmux-restore.log</string>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PLIST
	launchctl bootout "gui/$(id -u)/$LABEL" 2> /dev/null || true
	if launchctl bootstrap "gui/$(id -u)" "$plist" 2> /dev/null; then
		say "Enabled the shutdown save: tmux is saved as you log out, restart or shut down"
	else
		warn "couldn't load $plist now; it starts at your next login"
	fi
}

# The unit runs in the systemd user manager, which stops with the user's last login session
# unless the user lingers. A detached tmux outlives a logout, and then nothing saves it: the
# minute-by-minute save runs from the status line, which tmux draws only for an attached client.
# Lingering keeps the shutdown save running for a tmux nobody is attached to or logged in for.
enable_linger() {
	local user=${USER:-$(id -un)}
	have loginctl || return 0
	[ "$(loginctl show-user "$user" -p Linger --value 2> /dev/null)" = yes ] && return 0
	if loginctl enable-linger > /dev/null 2>&1; then
		say "Enabled lingering for $user: the shutdown save keeps running after you log out"
	else
		warn "couldn't enable lingering: after you log out, a detached tmux is only saved while a client is attached. Run: sudo loginctl enable-linger $user"
	fi
}

install_service() {
	if [ "$(uname -s)" = Darwin ]; then
		install_launch_agent
		return
	fi
	if ! user_systemd; then
		[ "$(uname -s)" = Linux ] && say "No systemd user session: tmux is saved every minute, but not at shutdown"
		return 0
	fi
	local dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user" legacy
	mkdir -p "$dir"
	sed "s|^ExecStart=.*|ExecStart=\"$PLUGINS/tmux-restore/scripts/shutdown-save.sh\"|" \
		"$PLUGINS/tmux-restore/systemd/$UNIT" > "$dir/$UNIT"
	systemctl --user daemon-reload
	systemctl --user enable -q "$UNIT"
	systemctl --user restart "$UNIT"
	say "Enabled $UNIT: tmux is saved right before shutdown and reboot"
	enable_linger
	# An older copy of this setup ran a unit with another name; two at once would save twice.
	if systemctl --user -q is-enabled tmux-shutdown-save.service 2> /dev/null; then
		legacy=$(systemctl --user cat tmux-shutdown-save.service 2> /dev/null | grep '^ExecStart=' || true)
		case $legacy in
		*tmux-restore/scripts/tmux-shutdown-save.sh*) systemctl --user disable -q --now tmux-shutdown-save.service ;;
		*) warn "tmux-shutdown-save.service also saves at shutdown; disable one of them: systemctl --user disable --now tmux-shutdown-save.service" ;;
		esac
	fi
}

# Load the plugins into a running tmux server (continuum only restores into a server that just
# started, so this never restores over your open sessions).
load_into_tmux() {
	tmux has-session 2> /dev/null || return 0
	tmux run-shell "$(tpm_path)" && say "Loaded into your running tmux server"
}

uninstall() {
	local tmp dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user" hook
	if [ -f "$CONF" ]; then
		tmp=$(mktemp)
		strip_block < "$CONF" > "$tmp"
		if same_file "$tmp" "$CONF"; then rm -f "$tmp"; else cat "$tmp" > "$CONF" && rm -f "$tmp" && say "Removed tmux-restore from $CONF"; fi
	fi
	if [ -e "$HOME/Library/LaunchAgents/$LABEL.plist" ]; then
		launchctl bootout "gui/$(id -u)/$LABEL" 2> /dev/null || true
		rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
		say "Removed the shutdown save ($LABEL)"
	fi
	if [ -e "$dir/$UNIT" ]; then
		user_systemd && systemctl --user disable -q --now "$UNIT" 2> /dev/null || true
		rm -f "$dir/$UNIT"
		user_systemd && systemctl --user daemon-reload || true
		say "Removed $UNIT"
	fi
	if tmux has-session 2> /dev/null; then # give the running server its own hooks back
		hook=$(tmux show-option -gqv @resurrect-hook-post-save-layout)
		case $hook in */tmux-restore/scripts/save-hook.sh)
			tmux set-option -g @resurrect-hook-post-save-layout "$(tmux show-option -gqv @tmux-restore-next-hook)"
			tmux set-option -gu @tmux-restore-next-hook ;;
		esac
		hook=$(tmux show-option -gqv @resurrect-hook-pre-restore-all)
		case $hook in */tmux-restore/scripts/pre-restore.sh)
			tmux set-option -g @resurrect-hook-pre-restore-all "$(tmux show-option -gqv @tmux-restore-next-pre-restore-hook)"
			tmux set-option -gu @tmux-restore-next-pre-restore-hook ;;
		esac
	fi
	[ -d "$PLUGINS/tmux-restore" ] && rm -rf "$PLUGINS/tmux-restore" && say "Removed $PLUGINS/tmux-restore"
	say "tmux-restore is uninstalled. tmux-resurrect and tmux-continuum are still installed."
}

main() {
	case ${1:-} in
	"" | --install) ;;
	--uninstall) ;;
	*) die "unknown option: $1 (use --uninstall to remove tmux-restore)" ;;
	esac
	CONF=$(tmux_conf)
	if [ "${1:-}" = --uninstall ]; then
		PLUGINS=$(plugins_dir)
		uninstall
		return
	fi
	install_deps
	PLUGINS=$(plugins_dir)
	install_plugins
	edit_conf
	install_service
	load_into_tmux
	say "Done. tmux is saved every minute and comes back when tmux starts, agents and all."
	say "Try it: save with prefix + Ctrl-s, run 'tmux kill-server', then start tmux again."
}

main "$@"
