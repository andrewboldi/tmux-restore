#!/usr/bin/env bash
# Python venvs end to end, with zsh and with bash. The shells source scripts/shell-hook.sh, panes
# activate a real venv in a folder whose name has a space and a quote, tmux-resurrect saves
# (running the save hook), and the server is killed and restored. Then each pane has its venv
# active again; with zsh, a command that comes back typed gets its venv first, and a venv deleted
# before the restore leaves its pane without one, and without an error. Throwaway servers in
# their own socket directory and HOME.
# PLUGINS_DIR (default ~/.tmux/plugins) must contain tmux-resurrect. Needs zsh, and uv or python3.
set -u
here=$(cd "$(dirname "$0")" && pwd)
PLUGINS_DIR=${PLUGINS_DIR:-$HOME/.tmux/plugins}
[[ -d $PLUGINS_DIR/tmux-resurrect ]] || { echo "FAIL: $PLUGINS_DIR/tmux-resurrect not found (set PLUGINS_DIR)"; exit 1; }
D=$(mktemp -d)
t() { TMUX_TMPDIR=$D/sock command tmux -L venv "$@"; }
trap 't kill-server 2> /dev/null; rm -rf "$D" /tmp/tmux-resurrect-restore-venv.lock' EXIT
mkdir -p "$D/sock" "$D/home" "$D/proj" "$D/plugins"
cp -rL "$PLUGINS_DIR/tmux-resurrect" "$D/plugins/" 2> /dev/null
cp -r "$here/.." "$D/plugins/tmux-restore"
pass=0 fail=0
check() { if [[ $2 == "$3" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL %s\n  want: [%s]\n  got:  [%s]\n' "$1" "$2" "$3"; fi; }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

mkvenv() { if command -v uv > /dev/null; then uv venv -q "$1"; else python3 -m venv --without-pip "$1"; fi; }
V="$D/my proj's/.venv" GONE="$D/gone/.venv"
q() { printf "'%s'" "${1//\'/\'\\\'\'}"; } # single-quoted for zsh and bash
hook="$D/plugins/tmux-restore/scripts/shell-hook.sh"
printf '%s\n' "PS1='$ '" ". $(q "$hook")" > "$D/home/.zshrc"
printf '%s\n' "PS1='$ '" ". $(q "$hook")" > "$D/home/.bashrc"
echo '. ~/.bashrc' > "$D/home/.bash_profile" # tmux-resurrect starts bash as a login shell

# start SHELL TMUX-ARGS...: a server whose panes run SHELL, with tmux-resurrect and tmux-restore
start() {
	cat > "$D/test.conf" <<EOC
set -g default-shell '$1'
set -g default-size 200x50
set -g @resurrect-dir '$D/resurrect'
set -g @continuum-restore 'off'
run-shell '$D/plugins/tmux-resurrect/resurrect.tmux'
run-shell '$D/plugins/tmux-restore/tmux-restore.tmux'
EOC
	shift
	env -i HOME="$D/home" PATH="$PATH" TERM=xterm-256color LANG="${LANG:-C.UTF-8}" TMUX_TMPDIR="$D/sock" \
		tmux -L venv -f "$D/test.conf" "$@"
}
# until CMD...: wait up to 10 s for CMD to succeed
until_ok() {
	local _
	for _ in $(seq 100); do "$@" && return 0; sleep 0.1; done
	return 1
}
shows() { [[ $(t capture-pane -p -t "$1") == *"$2"* ]]; }
prompt() { t capture-pane -p -t "$1" | grep -q '\$$'; } # capture-pane drops the space after "$"
venv_of() { t show-option -pqv -t "$1" @tmux-restore-venv; }
has_venv() { [[ -n $(venv_of "$1") ]]; }
# report PANE: the pane writes the venv it has active to $D/out.PANE
report() {
	rm -f "$D/out.$1"
	t send-keys -t "main:0.$1" C-u "printf '%s\n' \"\${VIRTUAL_ENV:-none}\" > '$D/out.$1'" Enter
	until_ok test -s "$D/out.$1"
	cat "$D/out.$1" 2> /dev/null
}

for sh in zsh bash; do
	rm -rf "$D/resurrect" "$V" "$GONE"
	mkvenv "$V" && mkvenv "$GONE" || { echo "FAIL: couldn't create a venv"; exit 1; }
	start "$(command -v $sh)" new-session -d -s main -c "$D/proj"
	t split-window -t main:0 -c "$D/proj"
	t split-window -t main:0 -c "$D/proj"
	until_ok prompt main:0.2 || bad "$sh: no prompt"
	# pane 0: a venv, idle. 1: a venv, then a command that isn't safe to re-run. 2: a venv that
	# is deleted before the restore (zsh), or nothing (bash)
	t send-keys -t main:0.0 ". $(q "$V/bin/activate")" Enter
	t send-keys -t main:0.1 ". $(q "$V/bin/activate")" Enter
	[[ $sh == zsh ]] && t send-keys -t main:0.2 ". $(q "$GONE/bin/activate")" Enter
	until_ok has_venv main:0.0 && until_ok has_venv main:0.1 || bad "$sh: the hook didn't report a venv"
	venv=$(venv_of main:0.0)
	check "$sh: the hook reports the venv" "my proj's/.venv" "${venv: -15}"
	if [[ $sh == zsh ]]; then
		until_ok has_venv main:0.2
		other=$(venv_of main:0.2)
		check "$sh: the hook reports the other venv" "gone/.venv" "${other: -10}"
	else
		sleep 0.5
		check "$sh: no venv, nothing reported" "" "$(venv_of main:0.2)"
	fi
	t send-keys -t main:0.1 'sleep 100000' Enter
	shell_pid=$(t display-message -p -t main:0.1 '#{pane_pid}')
	until_ok pgrep -P "$shell_pid" -x sleep > /dev/null || bad "$sh: sleep didn't start"
	sleep_pid=$(pgrep -P "$shell_pid" -x sleep)

	t run-shell "$D/plugins/tmux-resurrect/scripts/save.sh quiet"
	saved=$(awk -F'\t' '$1 == "pane" { print $6 "\t" $11 }' "$D/resurrect/last")
	a=". $(q "$venv/bin/activate") 2> /dev/null"
	check "$sh: saved, idle pane" ":TMUX_RESTORE=1 $a" "$(awk -F'\t' '$1 == 0 { print $2 }' <<< "$saved")"
	if [[ $sh == zsh ]]; then
		check "$sh: saved, typed command" ":TMUX_RESTORE=1 $a; print -rz -- 'sleep 100000'" "$(awk -F'\t' '$1 == 1 { print $2 }' <<< "$saved")"
	else
		check "$sh: saved, command left as it was" ":sleep 100000" "$(awk -F'\t' '$1 == 1 { print $2 }' <<< "$saved")"
	fi
	t kill-server
	[[ -n $sleep_pid ]] && kill "$sleep_pid" 2> /dev/null
	rm -rf "$GONE"

	start "$(command -v $sh)" new-session -d -s scratch
	t run-shell "$D/plugins/tmux-resurrect/scripts/restore.sh"
	until_ok prompt main:0.2 || bad "$sh: restored panes have no prompt"
	check "$sh: restored, idle pane has its venv" "$venv" "$(report 0)"
	if [[ $sh == zsh ]]; then
		until_ok shows main:0.1 'sleep 100000' || bad "$sh: the command wasn't typed back"
		check "$sh: restored, typed command has its venv" "$venv" "$(report 1)"
		check "$sh: restored, deleted venv: none" "none" "$(report 2)"
		check "$sh: restored, deleted venv: no error shown" "" "$(t capture-pane -p -t main:0.2 | grep -i 'no such file')"
	else
		check "$sh: restored, pane without a venv" "none" "$(report 2)"
	fi
	t kill-server
done
echo "passed=$pass failed=$fail"; ((fail == 0))
