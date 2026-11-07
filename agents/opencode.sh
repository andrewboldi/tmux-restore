# shellcheck shell=bash
# opencode (https://opencode.ai)
#
# opencode keeps sessions in a SQLite database and doesn't record which process has which one
# open. This picks the newest top-level session in the process's directory that was updated after
# the process started, and only when no other opencode works in that directory. Before anything
# is written, it uses the session the process was started with (-s), if any.

# shellcheck disable=SC2034 # read by keep_flags and first_word (scripts/lib.sh)
opencode_value_flags="-m --model -s --session --prompt --agent --port --hostname --mdns-domain --log-level --replay-limit"
opencode_variadic_flags="--cors"
opencode_drop_flags="-c --continue -s --session --fork --prompt"

opencode_match() {
	local comm
	comm=$(proc_comm "$1") || return 1
	# opencode 2.x ships the native binary as opencode.exe.
	[[ $comm == opencode || $comm == opencode.exe ]] && proc_args "$1" || return 1
	# Subcommands aren't the interactive TUI. Any other positional word is the project directory.
	case $(first_word opencode "${ARGV[@]}") in
	acp | mcp | attach | run | debug | providers | auth | agent | upgrade | uninstall | serve | web | models | stats | export | import | github | pr | session | plugin | plug | db | completion) return 1 ;;
	esac
}

opencode_db() {
	local data db
	data=$(proc_env "$1" XDG_DATA_HOME)
	data=${data:-$HOME/.local/share}/opencode
	db=$(proc_env "$1" OPENCODE_DB)
	case $db in
	"") db=$data/opencode.db ;;
	:memory:) return 1 ;;
	/*) ;;
	*) db=$data/$db ;;
	esac
	[[ -r $db ]] && printf '%s\n' "$db"
}

opencode_session() {
	local db cwd since id="" dir table
	if alone_in_cwd "$1" && db=$(opencode_db "$1") && cwd=$(proc_cwd "$1") && since=$(proc_start_epoch "$1"); then
		dir=${cwd//\'/\'\'}
		# opencode 2.x stores sessions in session_v2; older versions in session.
		for table in session_v2 session; do
			id=$(sqlite3 -readonly -cmd ".timeout 2000" "$db" \
				"SELECT id FROM $table WHERE parent_id IS NULL AND directory = '$dir' AND time_updated >= $((since * 1000)) ORDER BY time_updated DESC LIMIT 1;" 2> /dev/null)
			[[ $id == ses_* ]] && break
		done
	fi
	if [[ $id != ses_* ]] && proc_args "$1"; then
		id=$(flag_value "-s --session" "${ARGV[@]}")
	fi
	[[ $id == ses_* ]] && printf '%s\n' "$id"
}

opencode_resume() {
	proc_args "$1" || return 1
	printf 'opencode -s %s%s' "$2" "$(keep_flags opencode "${ARGV[@]}")"
}

opencode_continue() {
	proc_args "$1" || return 1
	printf 'opencode -c%s' "$(keep_flags opencode "${ARGV[@]}")"
}
