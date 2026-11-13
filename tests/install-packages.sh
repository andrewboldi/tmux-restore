#!/usr/bin/env bash
# install.sh on Arch: packages are installed without a partial upgrade (pacman -S, never -Sy), and
# when pacman can't install them, the installer stops and says to update the system first. Runs
# install.sh's functions against a fake pacman.
set -u
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
pass=0 fail=0
check() { if [[ $2 == "$3" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL %s\n  want: [%s]\n  got:  [%s]\n' "$1" "$2" "$3"; fi; }

mkdir -p "$D/bin"
cat > "$D/bin/pacman" <<'EOF'
#!/bin/sh
echo "$*" >> "$FAKE/calls"
if [ -e "$FAKE/refuse" ]; then
	echo "error: failed to prepare transaction (could not satisfy dependencies)" >&2
	exit 1
fi
EOF
chmod +x "$D/bin/pacman"
export FAKE=$D PATH="$D/bin:$PATH"

# run FUNCTION ARG...: one of install.sh's functions, on what looks like an Arch machine (pacman
# is the only package manager, and no sudo is needed); its output goes to $D/out
run() {
	# shellcheck disable=SC2016 # expanded by the inner bash
	TMUX_RESTORE_INSTALL_LIB=1 bash -c '
		source "$1" || exit 99
		shift
		uname() { echo Linux; }
		have() { [ "$1" = pacman ]; }
		as_root() { "$@"; }
		"$@"' _ "$here/../install.sh" "$@" > "$D/out" 2>&1
}

: > "$D/calls"
run install_packages tmux git jq
check "pacman: installs" 0 "$?"
check "pacman: no partial upgrade (-S, not -Sy)" "-S --noconfirm --needed tmux git jq" "$(cat "$D/calls")"

touch "$D/refuse"
run install_packages tmux
check "pacman fails: the installer stops" 1 "$?"
grep -q 'could not satisfy dependencies' "$D/out" && shown=yes || shown=no
check "pacman fails: its own error is shown" yes "$shown"
grep -q 'sudo pacman -Syu' "$D/out" && hint=yes || hint=no
check "pacman fails: says to update the system first" yes "$hint"

echo "passed=$pass failed=$fail"; ((fail == 0))
