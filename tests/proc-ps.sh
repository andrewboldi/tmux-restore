#!/usr/bin/env bash
# scripts/lib.sh's ps fallback, the one macOS uses, run on any system (on Linux, /proc is turned
# off). ps cuts its last column to the terminal width ($COLUMNS, or 80 columns on macOS when
# piped) unless it gets -ww, so a long command line, or a long path to the executable, came back
# cut short. Checked with each process looked up by itself, and from the save hook's snapshot.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/lib.sh
source "$here/../scripts/lib.sh"
HAVE_PROCFS=""
export COLUMNS=80
D=$(mktemp -d)
D=$(cd "$D" && pwd -P)
pids=() withargs=""
# The background processes write nowhere, so a pipe reading this test's output isn't held open.
trap 'pkill -P "$withargs" 2> /dev/null; kill "${pids[@]}" 2> /dev/null; rm -rf "$D"' EXIT
pass=0 fail=0
check() { if [[ $2 == "$3" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL %s\n  want: [%s]\n  got:  [%s]\n' "$1" "$2" "$3"; fi; }

# An agent with a long argument, run from a long path: a copy of sleep named codex. (A
# multi-call coreutils won't run under another name; then the path check is skipped.)
long=$(printf 'x%.0s' {1..300})
bin="$D/$(printf 'd%.0s' {1..100})"
mkdir -p "$bin"
cp "$(command -v sleep)" "$bin/codex"
"$bin/codex" 0 2> /dev/null && named=1 || named=""
bash -c 'sleep 300; : "$0"' "$long" > /dev/null 2>&1 &
pids+=($!)
withargs=$!
if [[ -n $named ]]; then
	"$bin/codex" 300 > /dev/null 2>&1 &
	pids+=($!)
	agent=$!
fi
sleep 1

for mode in "one at a time" snapshot; do
	[[ $mode == snapshot ]] && proc_snapshot
	proc_argv "$withargs"
	check "$mode: the last argument is whole" "${#long}" "${#ARGV[${#ARGV[@]} - 1]}"
	check "$mode: proc_ppid" "$$" "$(proc_ppid "$withargs")"
	check "$mode: proc_children" yes "$(proc_children $$ | grep -qx "$withargs" && echo yes || echo no)"
	[[ -n $named ]] && check "$mode: proc_comm from a long path" codex "$(proc_comm "$agent")"
	check "$mode: no such process" 1 "$(proc_argv 999999999 && echo 0 || echo 1)"
done

echo "passed=$pass failed=$fail ($(uname -s))"
((fail == 0))
