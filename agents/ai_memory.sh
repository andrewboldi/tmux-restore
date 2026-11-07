# shellcheck shell=bash
# ai-memory (https://github.com/akitaonrails/ai-memory)
#
# `ai-memory run <harness>` launches a coding agent as a child process and keeps
# ai-memory's own hooks and MCP in the loop. Reopen the harness's conversation
# through ai-memory again, so a restored pane keeps the wrapper instead of
# falling back to a bare agent (which would lose the memory integration).
#
# The harness is found from the child process; its conversation is detected by
# that harness's own adapter (claude, codex, gemini, opencode, pi).

ai_memory_match() {
	[[ $(proc_comm "$1") == ai-memory || $(proc_name "$1") == ai-memory ]] && proc_args "$1" || return 1
	case ${ARGV[0]:-} in run) return 0 ;; esac
	return 1
}

# ai_memory_harness PID: the adapter name and pid of the harness it launched.
ai_memory_harness() {
	local child name
	for child in $(proc_children "$1"); do
		for name in "${AGENTS[@]}"; do
			[[ $name == ai_memory ]] && continue
			"${name}_match" "$child" 2> /dev/null || continue
			printf '%s %s\n' "$name" "$child"
			return 0
		done
	done
	return 1
}

ai_memory_session() {
	local harness child
	read -r harness child < <(ai_memory_harness "$1") || return 1
	"${harness}_session" "$child"
}

ai_memory_resume() {
	local harness child cmd
	read -r harness child < <(ai_memory_harness "$1") || return 1
	cmd=$("${harness}_resume" "$child" "$2") || return 1
	printf 'ai-memory run %s %s' "$harness" "${cmd#* }"
}

ai_memory_continue() {
	local harness child cmd
	read -r harness child < <(ai_memory_harness "$1") || return 1
	declare -F "${harness}_continue" > /dev/null || return 1
	cmd=$("${harness}_continue" "$child") || return 1
	printf 'ai-memory run %s %s' "$harness" "${cmd#* }"
}
