#!/usr/bin/env bash
# tmux-resurrect post-save-layout hook: runs after every save, with the save file as $1, and
# rewrites the command saved for each pane so that a restore does the right thing:
#   coding agent   -> the agent's resume command (agents/*.sh): reopens the same conversation
#   safe program   -> unchanged; resurrect re-runs it (its defaults plus @resurrect-processes)
#   anything else  -> with zsh, typed on the prompt and waiting for Enter; with other shells
#                     unchanged, and resurrect doesn't re-run it
# Rewritten commands start with TMUX_RESTORE=1, which tmux-restore.tmux adds to
# @resurrect-processes so that resurrect runs them.

if ((BASH_VERSINFO[0] < 4)); then # macOS ships bash 3.2
	for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [[ -x $b ]] && exec "$b" "$0" "$@"; done
	exit 0
fi
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/scripts/lib.sh"
MARK="TMUX_RESTORE=1 "
AGENTS=() RESTORE_LIST=()

# Source agents/*.sh, then yours from ~/.config/tmux-restore/agents/ (the same name replaces ours).
load_agents() {
	local f name
	for f in "$ROOT"/agents/*.sh "${XDG_CONFIG_HOME:-$HOME/.config}"/tmux-restore/agents/*.sh; do
		[[ -r $f ]] || continue
		name=${f##*/}
		name=${name%.sh}
		# shellcheck source=/dev/null
		source "$f" || continue
		declare -F "${name}_match" "${name}_session" "${name}_resume" > /dev/null || continue
		[[ " ${AGENTS[*]} " == *" $name "* ]] || AGENTS+=("$name")
	done
}

# zsh code that puts $1 on the next prompt's edit line without running it.
prefill() {
	printf "print -rz -- '%s'" "${1//\'/\'\\\'\'}"
}

# RESTORE_LIST: the entries resurrect picks programs to restart by, its defaults plus
# @resurrect-processes.
restore_list() {
	local list
	list=$(tmux show -gqv @resurrect-default-processes)
	list="${list:-vi vim view nvim emacs man less more tail top htop irssi weechat mutt} $(tmux show -gqv @resurrect-processes)"
	eval "RESTORE_LIST=($list)"
}

# safe CMD: resurrect restarts CMD by itself, so it's left as it is. By resurrect's own rules,
# "a b" matches a command starting with "a b", "x->y" matches by its x, and "~x" matches x
# anywhere. A ~pattern counts only with "->": resurrect relaunches those anyway, taking their
# arguments from the saved command, which must stay as it was. A plain ~pattern comes back typed.
safe() {
	local entry match re1 re2
	for entry in "${RESTORE_LIST[@]}"; do
		match=${entry%%->*}
		if [[ $match == '~'* ]]; then
			[[ $entry == *'->'* ]] || continue
			re1="(${match#\~})" re2=$re1
		else
			re1="(^$match )" re2="(^$match\$)"
		fi
		[[ $1 =~ $re1 || $1 =~ $re2 ]] && return 0
	done
	return 1
}

# "systemd-run ... MemoryMax=N " when PID runs in a memory-capped systemd scope
# (e.g. started via `systemd-run --user --scope -p MemoryMax=8G claude`).
scope_prefix() {
	local cgroup max
	cgroup=$(cut -d: -f3- "$PROC/$1/cgroup" 2>/dev/null) || return 0
	[[ $cgroup == */run-*.scope ]] || return 0
	max=$(< "/sys/fs/cgroup$cgroup/memory.max") 2>/dev/null || return 0
	[[ $max == max ]] || printf 'systemd-run --user --scope -q -p MemoryMax=%s ' "$max"
}

# tmux-resurrect records a program that renamed itself (process.title, e.g. `npm run dev`) as
# its new name, escaped, plus one '' per leftover byte of the old command line:
# "npm\ run\ dev '' '' ...". Drop the ''s, and show a lone escaped name as typed.
tidy() {
	local cmd=$1
	while [[ $cmd == *" ''" ]]; do cmd=${cmd% \'\'}; done
	[[ $cmd == *[!\\]" "* ]] || cmd=${cmd//\\ / }
	printf '%s' "$cmd"
}

# What to save for a command that isn't an agent's conversation.
plain() {
	local cmd=$1
	if [[ -n $cmd && -n $ZSH ]] && ! safe "$cmd"; then
		printf '%s%s' "$MARK" "$(prefill "$cmd")"
	else
		printf '%s' "$cmd"
	fi
}

# rewrite PANE_PID CMD: set NEW to the command to save for the pane, and KEY to what it reopens
# when that was worked out by a heuristic (a conversation, or "the latest in this directory").
rewrite() {
	local pane_pid=$1 cmd=$2 pid agent id
	NEW="" KEY=""
	if [[ -n $pane_pid ]]; then
		for pid in "$pane_pid" $(proc_children "$pane_pid"); do
			for agent in "${AGENTS[@]}"; do
				"${agent}_match" "$pid" 2> /dev/null || continue
				if id=$("${agent}_session" "$pid" 2> /dev/null) && [[ -n $id ]] &&
					NEW=$("${agent}_resume" "$pid" "$id" 2> /dev/null) && [[ -n $NEW ]]; then
					NEW="$MARK$(scope_prefix "$pid")$NEW"
					# An exact adapter's id is real even when two panes share it (one conversation open
					# twice); only a guess can collide.
					local exact=${agent}_exact
					[[ -n ${!exact:-} ]] || KEY="$agent:$id"
					return
				fi
				if declare -F "${agent}_continue" > /dev/null &&
					NEW=$("${agent}_continue" "$pid" 2> /dev/null) && [[ -n $NEW ]]; then
					NEW="$MARK$(scope_prefix "$pid")$NEW"
					KEY="$agent:latest:$(proc_cwd "$pid")"
					return
				fi
				break 2 # an agent we can't reopen: save its command as a plain one
			done
		done
	fi
	NEW=$(plain "$cmd")
}

# A post-save-layout hook you had before tmux-restore runs after ours (tmux-restore.tmux keeps it).
run_next_hook() {
	local next
	next=$(tmux show -gqv @tmux-restore-next-hook)
	[[ -n $next ]] && eval "$next $(printf '%q' "$1")"
	return 0
}

main() {
	local save_file=$1 line cmd target pid i
	local -a lines out heads cmds keys fields
	local -A pane_pids count
	# The save folder also gets every pane's scrollback, which can hold secrets: keep it private.
	chmod 700 "$(dirname "$save_file")" 2> /dev/null
	load_agents
	restore_list
	ZSH=""
	[[ $(tmux show -gqv default-shell) == */zsh ]] && ZSH=1 # restored panes run default-shell
	while IFS=$'\t' read -r target pid; do pane_pids[$target]=$pid; done \
		< <(tmux list-panes -a -F $'#{session_name}:#{window_index}.#{pane_index}\t#{pane_pid}')

	mapfile -t lines < "$save_file"
	for i in "${!lines[@]}"; do
		line=${lines[i]}
		keys[i]=""
		if [[ $line != pane$'\t'* ]]; then
			out[i]=$line
			continue
		fi
		heads[i]=${line%$'\t'*}
		cmd=${line##*$'\t':} # last field minus resurrect's ":" prefix
		cmds[i]=$(tidy "${cmd% }")
		mapfile -td $'\t' fields < <(printf '%s' "${heads[i]}")
		target="${fields[1]}:${fields[2]}.${fields[5]}"
		rewrite "${pane_pids[$target]:-}" "${cmds[i]}"
		out[i]="${heads[i]}"$'\t'":$NEW"
		keys[i]=$KEY
		[[ -n $KEY ]] && count[$KEY]=$((${count[$KEY]:-0} + 1))
	done
	# Two panes that would reopen the same conversation (or "the latest" in the same directory)
	# would show it twice and lose the other one, so save them as plain commands instead.
	for i in "${!keys[@]}"; do
		if [[ -n ${keys[i]} ]] && ((count[${keys[i]}] > 1)); then
			out[i]="${heads[i]}"$'\t'":$(plain "${cmds[i]}")"
		fi
	done
	((${#out[@]})) && printf '%s\n' "${out[@]}" > "$save_file.tmp" && mv -f "$save_file.tmp" "$save_file"
	run_next_hook "$save_file"
}

[[ ${BASH_SOURCE[0]} == "$0" ]] && main "$@"
