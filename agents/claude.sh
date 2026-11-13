# shellcheck shell=bash
# Claude Code (https://claude.com/claude-code)
#
# Reopens the exact conversation. Claude Code registers each running session in
# ~/.claude/sessions/<pid>.json together with the process start time, so a recycled pid can't
# match, and the entry follows /clear: the pane gets the conversation it was actually in.

# Flags that take a value (claude --help, v2.1.316), so a value isn't mistaken for the prompt.
# shellcheck disable=SC2034 # the flag lists are read by keep_flags (scripts/lib.sh)
claude_value_flags="--agent --agents --append-system-prompt --autocompact --debug-file --effort --environment --fallback-model --input-format --json-schema --max-budget-usd --model -n --name --output-format --permission-mode --permission-prompts --plugin-dir --plugin-url --remote-control-session-name-prefix --session-id --setting-sources --settings --system-prompt --system-prompt-snapshot"
claude_variadic_flags="--add-dir --allowedTools --allowed-tools --betas --disallowedTools --disallowed-tools --file --mcp-config --tools"
claude_optional_flags="--cloud -d --debug --from-pr --prompt-suggestions --remote-control -r --resume --teleport -w --worktree"
# Flags that pick or start a conversation; replaced by --resume <id>.
claude_drop_flags="-c --continue -r --resume --session-id --fork-session --from-pr --teleport"

claude_dir() { printf '%s' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; }

claude_exact=1 # the registry says which conversation each process has open
claude_match() {
	[[ $(proc_comm "$1") == claude ]] && proc_args "$1" || return 1
	# A subcommand (claude --help, v2.1.325) isn't a conversation, so it's saved like any other
	# command. Remote Control (rc) isn't one either, but comes back as it was: claude_restart.
	case ${ARGV[0]:-} in
	agents | attach | auth | auto-mode | doctor | gateway | import | install | logs | mcp | plugin | plugins | purge | respawn | rm | setup-token | stop | kill | ultrareview | update | upgrade) return 1 ;;
	esac
}

# Remote Control (`claude rc`, `claude remote-control`) has no conversation of its own: start it
# again with the same arguments.
claude_restart() {
	proc_args "$1" || return 1
	[[ ${ARGV[0]:-} == rc || ${ARGV[0]:-} == remote-control ]] || return 1
	printf 'claude'
	printf ' %q' "${ARGV[@]}"
}

claude_session() {
	local sid start
	read -r sid start < <(jq -r 'select(.kind == "interactive") | "\(.sessionId) \(.procStart)"' \
		"$(claude_dir)/sessions/$1.json" 2> /dev/null)
	[[ -n $sid && $sid != null ]] || return 1
	# The start time is a Linux clock-tick count; without /proc, trust the pid.
	[[ -z $HAVE_PROCFS || $start == "$(proc_start "$1")" ]] || return 1
	printf '%s\n' "$sid"
}

claude_resume() {
	local pid=$1 id=$2 flag=--resume
	# Before anything is typed there's no transcript to resume: start a session with that id.
	compgen -G "$(claude_dir)/projects/*/$id.jsonl" > /dev/null || flag=--session-id
	proc_args "$pid" || return 1
	printf 'claude %s %s%s' "$flag" "$id" "$(keep_flags claude "${ARGV[@]}")"
}

claude_continue() {
	proc_args "$1" || return 1
	printf 'claude --continue%s' "$(keep_flags claude "${ARGV[@]}")"
}
