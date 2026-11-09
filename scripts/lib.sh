# shellcheck shell=bash
# Helpers for the save hook and the agent adapters (sourced by bash 4+).
#
# Process inspection reads /proc on Linux and falls back to ps and lsof elsewhere.
# TMUX_RESTORE_PROC points it at a fake /proc tree instead (used by the tests).

PROC=${TMUX_RESTORE_PROC:-/proc}
if [[ -n ${TMUX_RESTORE_PROC:-} || -r /proc/self/cmdline ]]; then HAVE_PROCFS=1; else HAVE_PROCFS=""; fi

# proc_argv PID: set the array ARGV to the command line of process PID.
# (Without /proc only an approximation: ps joins the arguments with spaces.)
proc_argv() {
	ARGV=()
	if [[ -n $HAVE_PROCFS ]]; then
		[[ -r $PROC/$1/cmdline ]] || return 1
		mapfile -td '' ARGV < "$PROC/$1/cmdline"
	else
		local args
		args=$(ps -o args= -p "$1" 2>/dev/null) || return 1
		read -ra ARGV <<< "$args"
	fi
	(( ${#ARGV[@]} ))
}

# proc_comm PID: the executable's name, as `ps -o comm` shows it (at most 15 chars on Linux).
proc_comm() {
	local comm
	if [[ -n $HAVE_PROCFS ]]; then
		[[ -r $PROC/$1/comm ]] && comm=$(<"$PROC/$1/comm") || return 1
	else
		comm=$(ps -o comm= -p "$1" 2>/dev/null) || return 1
	fi
	printf '%s\n' "${comm##*/}"
}

# proc_name PID: the program's name. That's argv[0] without its directory, or for a script run by
# an interpreter (node, python, a shell, ...), the script's name without .js/.mjs/.cjs/.py:
# "node /usr/bin/gemini" -> gemini.
proc_name() {
	proc_argv "$1" || return 1
	local exe=${ARGV[0]##*/} arg
	case $exe in
	node | nodejs | bun | deno | python | python3* | ruby | perl | sh | bash | dash | zsh)
		for arg in "${ARGV[@]:1}"; do
			[[ $arg == -* ]] && continue
			arg=${arg##*/}
			case $arg in *.js | *.mjs | *.cjs | *.py) arg=${arg%.*} ;; esac
			printf '%s\n' "$arg"
			return 0
		done
		;;
	esac
	printf '%s\n' "$exe"
}

# proc_args PID: set ARGV to the arguments after the program (and after the script, for an
# interpreter): "node /usr/bin/gemini -m pro" -> (-m pro).
proc_args() {
	proc_argv "$1" || return 1
	local exe=${ARGV[0]##*/} i=1
	case $exe in
	node | nodejs | bun | deno | python | python3* | ruby | perl | sh | bash | dash | zsh)
		while (( i < ${#ARGV[@]} )) && [[ ${ARGV[i]} == -* ]]; do i=$((i + 1)); done
		i=$((i + 1))
		;;
	esac
	ARGV=("${ARGV[@]:i}")
}

# proc_children PID: the pids of its child processes, one per line.
proc_children() {
	if [[ -n $HAVE_PROCFS ]] && compgen -G "$PROC/$1/task/*/children" > /dev/null; then
		cat "$PROC/$1"/task/*/children 2> /dev/null | tr ' ' '\n' | grep -v '^$'
	else
		pgrep -P "$1" 2>/dev/null
	fi
	return 0
}

# proc_descendants PID: children, grandchildren, ... one per line.
proc_descendants() {
	local c
	for c in $(proc_children "$1"); do
		printf '%s\n' "$c"
		proc_descendants "$c"
	done
}

# proc_cwd PID: its working directory.
proc_cwd() {
	if [[ -n $HAVE_PROCFS ]]; then
		readlink "$PROC/$1/cwd"
	else
		lsof -a -d cwd -p "$1" -Fn 2>/dev/null | sed -n 's/^n//p'
	fi
}

# proc_open_files PID: paths of the files it has open, one per line.
proc_open_files() {
	if [[ -n $HAVE_PROCFS ]]; then
		local fd
		for fd in "$PROC/$1"/fd/*; do readlink "$fd"; done 2>/dev/null
	else
		lsof -p "$1" -Fn 2>/dev/null | sed -n 's/^n//p'
	fi
	return 0
}

# proc_start PID: when it started. On Linux, clock ticks after boot (field 22 of /proc/PID/stat).
proc_start() {
	if [[ -n $HAVE_PROCFS ]]; then
		local stat
		[[ -r $PROC/$1/stat ]] && stat=$(<"$PROC/$1/stat") || return 1
		stat=${stat##*) } # drop "pid (comm) "; comm may contain spaces
		read -ra stat <<< "$stat"
		printf '%s\n' "${stat[19]}"
	else
		ps -o lstart= -p "$1" 2>/dev/null
	fi
}

# proc_start_epoch PID: when it started, in seconds since the epoch.
proc_start_epoch() {
	if [[ -n $HAVE_PROCFS ]]; then
		local ticks btime line hz
		ticks=$(proc_start "$1") || return 1
		while read -r line; do [[ $line == "btime "* ]] && btime=${line#btime }; done < "$PROC/stat"
		hz=$(getconf CLK_TCK 2> /dev/null || echo 100)
		[[ -n ${btime:-} ]] && printf '%s\n' $((btime + ticks / hz))
	else
		local lstart
		lstart=$(ps -o lstart= -p "$1" 2> /dev/null) || return 1
		date -j -f '%a %b %d %T %Y' "$lstart" +%s 2> /dev/null
	fi
}

# proc_env PID NAME: the value of environment variable NAME in process PID (empty if unset or
# unreadable). Adapters use it to find an agent's data directory as that process sees it.
proc_env() {
	[[ -n $HAVE_PROCFS && -r $PROC/$1/environ ]] || return 0
	local var
	while IFS= read -r -d '' var; do
		[[ $var == "$2="* ]] && { printf '%s\n' "${var#*=}"; return 0; }
	done < "$PROC/$1/environ"
	return 0
}

# proc_exe PID: the executable's path (Linux only; empty elsewhere).
proc_exe() { [[ -n $HAVE_PROCFS ]] && readlink "$PROC/$1/exe" 2> /dev/null; return 0; }

# procs_named COMM: pids of the processes whose executable name is COMM.
procs_named() {
	if [[ -n $HAVE_PROCFS ]]; then
		local f comm
		for f in "$PROC"/[0-9]*/comm; do
			{ read -r comm < "$f"; } 2> /dev/null || continue
			[[ $comm == "$1" ]] && { f=${f%/comm}; printf '%s\n' "${f##*/}"; }
		done
	else
		pgrep -x "$1" 2> /dev/null
	fi
	return 0
}

# proc_ppid PID: its parent's pid.
proc_ppid() {
	if [[ -n $HAVE_PROCFS ]]; then
		local stat
		[[ -r $PROC/$1/stat ]] && stat=$(<"$PROC/$1/stat") || return 1
		stat=${stat##*) }
		read -ra stat <<< "$stat"
		printf '%s\n' "${stat[1]}"
	else
		ps -o ppid= -p "$1" 2> /dev/null | tr -d ' '
	fi
}

# alone_in_cwd PID [MATCH]: no other process of the same program (by proc_name) works in PID's
# directory, not counting PID's own parent and children (a wrapper, a relaunched child). With
# MATCH, an adapter's match function, only processes it accepts count: opencode 2.x runs a
# background server, often in ~, that has no conversation open.
# Adapters that can only tell sessions apart by directory use this, so they never pick the same
# session for two panes.
alone_in_cwd() {
	local comm name cwd parent p
	comm=$(proc_comm "$1") && name=$(proc_name "$1") && cwd=$(proc_cwd "$1") || return 1
	parent=$(proc_ppid "$1")
	for p in $(procs_named "$comm"); do
		[[ $p == "$1" || $p == "$parent" || $(proc_ppid "$p") == "$1" ]] && continue
		[[ $(proc_name "$p") == "$name" && $(proc_cwd "$p") == "$cwd" ]] || continue
		[[ -z ${2:-} ]] || ("$2" "$p") || continue # a subshell: match functions set ARGV
		return 1
	done
	return 0
}

# iso_epoch TIME: an ISO 8601 time (2026-10-31T18:24:23.123Z) in seconds since the epoch.
iso_epoch() {
	[[ -n $1 ]] || return 1
	date -d "$1" +%s 2> /dev/null || TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%S' "${1%%.*}" +%s 2> /dev/null
}

# file_mtime FILE: when FILE was last modified, in seconds since the epoch.
file_mtime() { stat -c %Y "$1" 2> /dev/null || stat -f %m "$1" 2> /dev/null; }

# keep_flags NAME ARG...: the flags worth keeping when a conversation is reopened, shell-quoted,
# each preceded by a space. Positional words (an initial prompt) are dropped. Uses the agent's
# flag lists, " "-separated:
#   NAME_value_flags     take one value                    --model opus
#   NAME_variadic_flags  take every following non-flag     --add-dir a b
#   NAME_optional_flags  take the next word unless a flag  --debug api
#   NAME_drop_flags      pick or start a conversation; the resume command replaces them
# so that a flag's value isn't mistaken for the prompt.
keep_flags() {
	local name=$1
	shift
	local v=${name}_value_flags va=${name}_variadic_flags o=${name}_optional_flags d=${name}_drop_flags
	local value=" ${!v:-} " variadic=" ${!va:-} " optional=" ${!o:-} " drop=" ${!d:-} "
	local -a args=("$@") out=() group=()
	local i=0 arg flag
	while (( i < ${#args[@]} )); do
		arg=${args[i++]}
		[[ $arg == -- ]] && break
		[[ $arg == -* ]] || continue
		flag=${arg%%=*}
		group=("$arg")
		if [[ $arg != *=* ]]; then
			if [[ $value == *" $flag "* ]]; then
				(( i < ${#args[@]} )) && group+=("${args[i++]}")
			elif [[ $variadic == *" $flag "* ]]; then
				while (( i < ${#args[@]} )) && [[ ${args[i]} != -* ]]; do group+=("${args[i++]}"); done
			elif [[ $optional == *" $flag "* ]] && (( i < ${#args[@]} )) && [[ ${args[i]} != -* ]]; then
				group+=("${args[i++]}")
			fi
		fi
		[[ $drop == *" $flag "* ]] || out+=("${group[@]}")
	done
	(( ${#out[@]} )) && printf ' %q' "${out[@]}"
	return 0
}

# first_word NAME ARG...: the first positional word (a subcommand, say), skipping flags and the
# values of NAME's value flags.
first_word() {
	local name=$1 arg
	shift
	local v=${name}_value_flags
	local value=" ${!v:-} "
	while (($#)); do
		arg=$1
		shift
		if [[ $arg == -- ]]; then
			(($#)) && printf '%s\n' "$1"
			return 0
		elif [[ $arg == -* ]]; then
			[[ $arg != *=* && $value == *" $arg "* ]] && shift
		else
			printf '%s\n' "$arg"
			return 0
		fi
	done
}

# flag_value "FLAG..." ARG...: the value given to the first of the FLAGs (--flag v or --flag=v).
flag_value() {
	local flags=" $1 " arg
	shift
	while (($#)); do
		arg=$1
		shift
		if [[ $arg == --*=* && $flags == *" ${arg%%=*} "* ]]; then
			printf '%s\n' "${arg#*=}"
			return 0
		elif [[ $flags == *" $arg "* ]] && (($#)); then
			printf '%s\n' "$1"
			return 0
		fi
	done
	return 1
}

# unique_line: print stdin if it is exactly one line, else fail. For adapters that match a
# process to a session by a heuristic: an ambiguous match must not pick a conversation.
unique_line() {
	local -a lines
	mapfile -t lines
	(( ${#lines[@]} == 1 )) && [[ -n ${lines[0]} ]] && printf '%s\n' "${lines[0]}"
}
