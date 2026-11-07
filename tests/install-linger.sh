#!/usr/bin/env bash
# install.sh turns on lingering when it's off, and --uninstall turns it off again only if the
# installer turned it on. Runs install.sh's functions against a fake loginctl.
set -u
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
pass=0 fail=0
check() { if [[ $2 == "$3" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL %s\n  want: [%s]\n  got:  [%s]\n' "$1" "$2" "$3"; fi; }

mkdir -p "$D/bin"
cat > "$D/bin/loginctl" <<'EOF'
#!/bin/sh
echo "$1" >> "$FAKE/calls"
case $1 in
show-user) cat "$FAKE/linger" ;;
enable-linger) [ -e "$FAKE/refuse" ] && exit 1; echo yes > "$FAKE/linger" ;;
disable-linger) [ -e "$FAKE/refuse" ] && exit 1; echo no > "$FAKE/linger" ;;
esac
EOF
chmod +x "$D/bin/loginctl"
# Nothing here may reach your tmux server or systemd.
for tool in tmux systemctl; do printf '#!/bin/sh\nexit 1\n' > "$D/bin/$tool" && chmod +x "$D/bin/$tool"; done
unset TMUX TMUX_PANE
export FAKE=$D PATH="$D/bin:$PATH" HOME=$D/home XDG_STATE_HOME=$D/state TMUX_TMPDIR=$D USER=tester
mark=$D/state/tmux-restore/enabled-linger

# setup LINGER [refuse] [mark]
setup() {
	rm -rf "$D/state" "$D/calls" "$D/refuse"
	echo "$1" > "$D/linger"
	[[ " $* " == *" refuse "* ]] && touch "$D/refuse"
	[[ " $* " == *" mark "* ]] && mkdir -p "$(dirname "$mark")" && touch "$mark"
}
# run FUNCTION: run one of install.sh's functions; its output is in $D/out
run() { TMUX_RESTORE_INSTALL_LIB=1 bash -c 'source "$1" && "$2"' _ "$here/../install.sh" "$1" > "$D/out" 2>&1; }
calls() { [[ -e $D/calls ]] && tr '\n' ' ' < "$D/calls"; }
said() { if grep -q "$1" "$D/out"; then echo yes; else echo no; fi; }
marked() { if [[ -e $mark ]]; then echo yes; else echo no; fi; }

setup yes
run enable_linger
check "already lingering: nothing to do"        "show-user "                "$(calls)"
check "already lingering: no mark"              no                          "$(marked)"
check "already lingering: says nothing"         ""                          "$(cat "$D/out")"

setup no
run enable_linger
check "off: turned on"                          yes                         "$(cat "$D/linger")"
check "off: marked as ours"                     yes                         "$(marked)"
check "off: says so"                            yes                         "$(said 'Enabled lingering for tester')"

setup no refuse
run enable_linger
check "refused: still off"                      no                          "$(cat "$D/linger")"
check "refused: no mark"                        no                          "$(marked)"
check "refused: gives the sudo command"         yes                         "$(said 'sudo loginctl enable-linger tester')"

setup yes mark
run disable_linger
check "uninstall, ours: turned off"             no                          "$(cat "$D/linger")"
check "uninstall, ours: mark removed"           no                          "$(marked)"
check "uninstall, ours: says so"                yes                         "$(said 'Turned lingering back off')"

setup yes
run disable_linger
check "uninstall, yours: left on"               yes                         "$(cat "$D/linger")"
check "uninstall, yours: loginctl not called"   ""                          "$(calls)"

setup yes refuse mark
run disable_linger
check "uninstall, refused: still on"            yes                         "$(cat "$D/linger")"
check "uninstall, refused: mark kept"           yes                         "$(marked)"
check "uninstall, refused: gives the sudo command" yes                      "$(said 'sudo loginctl disable-linger tester')"

echo "passed=$pass failed=$fail"
((fail == 0))
