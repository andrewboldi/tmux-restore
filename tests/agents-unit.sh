#!/usr/bin/env bash
# The save hook end to end against a fake /proc tree (TMUX_RESTORE_PROC) and a stub tmux: which
# command each pane gets, per agent adapter, and the shared rules (fallbacks, collisions, your
# own adapters, a hook you already had).
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
export TMUX_RESTORE_PROC=$D/proc XDG_CONFIG_HOME=$D/config CLAUDE_CONFIG_DIR=$D/claude
# shellcheck source=scripts/save-hook.sh
source "$here/../scripts/save-hook.sh"
pass=0 fail=0
check() { if [[ $2 == "$3" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL %s\n  want: [%s]\n  got:  [%s]\n' "$1" "$2" "$3"; fi; }

# mkproc PID PPID CWD START ARG...: a fake process (comm = ARG's basename, cut to 15 chars), START
# in clock ticks after boot. EXE= sets its executable (default ARG, or /usr/bin/ARG), ENVIRON= its
# environment ("A=1 B=2").
mkproc() {
	local pid=$1 ppid=$2 cwd=$3 start=$4 comm exe e
	shift 4
	comm=${1##*/}
	comm=${comm:0:15}
	mkdir -p "$TMUX_RESTORE_PROC/$pid/fd" "$TMUX_RESTORE_PROC/$pid/task/$pid"
	printf '%s\0' "$@" > "$TMUX_RESTORE_PROC/$pid/cmdline"
	printf '%s\n' "$comm" > "$TMUX_RESTORE_PROC/$pid/comm"
	printf '%s (%s) S %s 0 0 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 %s 0 0\n' "$pid" "$comm" "$ppid" "$start" > "$TMUX_RESTORE_PROC/$pid/stat"
	ln -s "$cwd" "$TMUX_RESTORE_PROC/$pid/cwd"
	exe=${EXE:-$1}
	[[ $exe == /* ]] || exe=/usr/bin/$exe
	ln -s "$exe" "$TMUX_RESTORE_PROC/$pid/exe"
	: > "$TMUX_RESTORE_PROC/$pid/environ"
	for e in ${ENVIRON:-}; do printf '%s\0' "$e" >> "$TMUX_RESTORE_PROC/$pid/environ"; done
	: > "$TMUX_RESTORE_PROC/$pid/task/$pid/children"
	[[ -d $TMUX_RESTORE_PROC/$ppid ]] && printf '%s ' "$pid" >> "$TMUX_RESTORE_PROC/$ppid/task/$ppid/children"
}
# setmtime FILE EPOCH: create FILE with that modification time (GNU or BSD touch)
setmtime() { touch -d "@$2" "$1" 2> /dev/null || touch -t "$(date -r "$2" +%Y%m%d%H%M.%S)" "$1"; }
# openfile PID PATH: PID has PATH open
openfile() { ln -s "$2" "$TMUX_RESTORE_PROC/$1/fd/$(ls "$TMUX_RESTORE_PROC/$1/fd" | wc -l | tr -d ' ')"; }

PANES=() SAVE=() SHELL_PATH=/usr/bin/zsh NEXT_HOOK=""
tmux() {
	case $1 in
	show) case ${3:-} in default-shell) echo "$SHELL_PATH" ;; @tmux-restore-next-hook) echo "$NEXT_HOOK" ;; esac ;;
	list-panes) printf '%s\n' "${PANES[@]}" ;;
	esac
}
# pane WINDOW PANE_PID SAVED_CMD: a pane in session "main", as tmux and the save file see it
pane() {
	local current=${3%% *}
	PANES+=("main:$1.0"$'\t'"$2")
	SAVE+=("$(printf 'pane\tmain\t%s\t1\t:*\t0\ttitle\t:/w\t1\t%s\t:%s' "$1" "${current:-zsh}" "$3")")
}
# run: apply the hook to the panes declared so far; GOT[WINDOW] = the command saved for it
run() {
	printf '%s\n' "${SAVE[@]}" > "$D/save"
	(main "$D/save")
	GOT=()
	local w cmd
	while IFS=$'\t' read -r w cmd; do GOT[w]=${cmd#:}; done < <(awk -F'\t' '{print $3 "\t" $11}' "$D/save")
}
reset() {
	rm -rf "$TMUX_RESTORE_PROC" "$CLAUDE_CONFIG_DIR" "$XDG_CONFIG_HOME" "$D/data" "$D/pi"
	mkdir -p "$TMUX_RESTORE_PROC"
	echo "btime 1700000000" > "$TMUX_RESTORE_PROC/stat" # so START 5000 (50 s) = 1700000050
	PANES=() SAVE=()
}

# --- Claude Code ------------------------------------------------------------------------------
claude_registry() { # PID SESSION START [no-transcript]
	mkdir -p "$CLAUDE_CONFIG_DIR/sessions" "$CLAUDE_CONFIG_DIR/projects/-w"
	printf '{"pid":%s,"sessionId":"%s","procStart":"%s","kind":"interactive"}\n' "$1" "$2" "$3" > "$CLAUDE_CONFIG_DIR/sessions/$1.json"
	[[ ${4:-} == no-transcript ]] || : > "$CLAUDE_CONFIG_DIR/projects/-w/$2.jsonl"
}
reset
mkproc 100 1 /w/a 10 /usr/bin/zsh; mkproc 101 100 /w/a 5000 claude --model opus 'fix the bug'; claude_registry 101 S1 5000
mkproc 200 1 /w/b 10 /usr/bin/zsh; mkproc 201 200 /w/b 5100 claude --effort max; claude_registry 201 S2 5100 no-transcript
mkproc 300 1 /w/c 10 /usr/bin/zsh; mkproc 301 300 /w/c 5200 claude -c --model opus; claude_registry 301 S3 9999   # stale entry
mkproc 400 1 /w/d 10 /usr/bin/zsh; mkproc 401 400 /w/d 5300 claude --model opus                                 # not registered
mkproc 500 1 /w/d 10 /usr/bin/zsh; mkproc 501 500 /w/d 5400 claude --model opus                                 # same dir as 401
mkproc 600 1 /w/f 5500 claude; claude_registry 600 S6 5500                                                      # pane runs claude itself
mkproc 700 1 /w/g 10 /usr/bin/zsh; mkproc 701 700 /w/g 5600 vim notes.txt
pane 0 100 "claude --model opus fix the bug"; pane 1 200 "claude --effort max"; pane 2 300 "claude -c --model opus"
pane 3 400 "claude --model opus"; pane 4 500 "claude --model opus"; pane 5 600 ""; pane 6 700 "vim notes.txt"
run
check "claude: exact id, prompt dropped"       "TMUX_RESTORE=1 claude --resume S1 --model opus"    "${GOT[0]}"
check "claude: nothing typed yet"              "TMUX_RESTORE=1 claude --session-id S2 --effort max" "${GOT[1]}"
check "claude: stale entry -> --continue"      "TMUX_RESTORE=1 claude --continue --model opus"     "${GOT[2]}"
check "claude: same-dir fallbacks -> typed 1"  "TMUX_RESTORE=1 print -rz -- 'claude --model opus'" "${GOT[3]}"
check "claude: same-dir fallbacks -> typed 2"  "TMUX_RESTORE=1 print -rz -- 'claude --model opus'" "${GOT[4]}"
check "claude: pane process is the agent"      "TMUX_RESTORE=1 claude --resume S6"                 "${GOT[5]}"
check "not an agent: safe program unchanged"   "vim notes.txt"                                     "${GOT[6]}"
SHELL_PATH=/bin/bash run
check "bash: same-dir fallbacks unchanged"     "claude --model opus"                               "${GOT[3]}"

reset # one conversation open in two panes: an exact adapter restores both
mkproc 100 1 /w/a 10 /usr/bin/zsh; mkproc 101 100 /w/a 5000 claude; claude_registry 101 S1 5000
mkproc 200 1 /w/b 10 /usr/bin/zsh; mkproc 201 200 /w/b 5100 claude --resume S1; claude_registry 201 S1 5100
pane 0 100 "claude"; pane 1 200 "claude --resume S1"
run
check "claude: one conversation in two panes (1)" "TMUX_RESTORE=1 claude --resume S1"                "${GOT[0]}"
check "claude: one conversation in two panes (2)" "TMUX_RESTORE=1 claude --resume S1"                "${GOT[1]}"

# --- opencode ---------------------------------------------------------------------------------
reset
mkdir -p "$D/data/opencode"
sqlite3 "$D/data/opencode/opencode.db" "CREATE TABLE session (id TEXT, parent_id TEXT, directory TEXT, time_updated INTEGER);
	INSERT INTO session VALUES ('ses_A1', NULL, '/w/a', 1700000100000), ('ses_A0', NULL, '/w/a', 1700000020000),
		('ses_Achild', 'ses_A1', '/w/a', 1700000200000), ('ses_B1', NULL, '/w/b', 1700000100000),
		('ses_F1', NULL, '/w/f', 1700000100000);"
E="XDG_DATA_HOME=$D/data"
mkproc 100 1 /w/a 10 /usr/bin/zsh; ENVIRON=$E mkproc 101 100 /w/a 5000 opencode --model anthropic/x
mkproc 200 1 /w/c 10 /usr/bin/zsh; ENVIRON=$E mkproc 201 200 /w/c 5000 opencode -s ses_OLD
mkproc 300 1 /w/b 10 /usr/bin/zsh; ENVIRON=$E mkproc 301 300 /w/b 5000 opencode
mkproc 400 1 /w/b 10 /usr/bin/zsh; ENVIRON=$E mkproc 401 400 /w/b 5000 opencode
mkproc 500 1 /w/d 10 /usr/bin/zsh; ENVIRON=$E mkproc 501 500 /w/d 5000 opencode run 'do x'
mkproc 600 1 /w/e 10 /usr/bin/zsh; ENVIRON=$E mkproc 601 600 /w/e 5000 opencode ../e
mkproc 700 1 /w/f 10 /usr/bin/zsh; ENVIRON=$E mkproc 701 700 /w/f 5000 /opt/opencode/bin/opencode.exe --model x
pane 0 100 "opencode --model anthropic/x"; pane 1 200 "opencode -s ses_OLD"; pane 2 300 "opencode"
pane 3 400 "opencode"; pane 4 500 "opencode run do x"; pane 5 600 "opencode ../e"
pane 6 700 "opencode.exe --model x"
run
check "opencode: newest top-level session here" "TMUX_RESTORE=1 opencode -s ses_A1 --model anthropic/x" "${GOT[0]}"
check "opencode: nothing written yet, keeps -s"  "TMUX_RESTORE=1 opencode -s ses_OLD"                    "${GOT[1]}"
check "opencode: two in one dir -> typed"        "TMUX_RESTORE=1 print -rz -- 'opencode'"               "${GOT[2]}"
check "opencode: two in one dir -> typed (2)"    "TMUX_RESTORE=1 print -rz -- 'opencode'"               "${GOT[3]}"
check "opencode: 'run' isn't the TUI"            "TMUX_RESTORE=1 print -rz -- 'opencode run do x'"      "${GOT[4]}"
check "opencode: nothing yet -> -c, dir dropped" "TMUX_RESTORE=1 opencode -c"                           "${GOT[5]}"
check "opencode: 2.x .exe binary"                "TMUX_RESTORE=1 opencode -s ses_F1 --model x"          "${GOT[6]}"

# opencode 2.x moved sessions to session_v2; older versions still use session
reset
mkdir -p "$D/data/opencode"
sqlite3 "$D/data/opencode/opencode.db" "CREATE TABLE session_v2 (id TEXT, parent_id TEXT, directory TEXT, time_updated INTEGER);
	INSERT INTO session_v2 VALUES ('ses_V2', NULL, '/w/v', 1700000100000), ('ses_M1', NULL, '/w/m', 1700000100000),
		('ses_S1', NULL, '/w/s', 1700000100000);"
E="XDG_DATA_HOME=$D/data"
mkproc 100 1 /w/v 10 /usr/bin/zsh; ENVIRON=$E mkproc 101 100 /w/v 5000 /opt/opencode/bin/opencode.exe
mkproc 200 1 /w/m 10 /usr/bin/zsh; ENVIRON=$E mkproc 201 200 /w/m 5000 opencode mini --model x
mkproc 300 1 /w/q 10 /usr/bin/zsh; ENVIRON=$E mkproc 301 300 /w/q 5000 opencode mini
mkproc 400 1 /w/s 10 /usr/bin/zsh; ENVIRON=$E mkproc 401 400 /w/s 5000 opencode --server http://localhost:4096
mkproc 500 1 /w/n 10 /usr/bin/zsh; ENVIRON=$E mkproc 501 500 /w/n 5000 opencode service status
mkproc 600 1 /w/p 10 /usr/bin/zsh; ENVIRON=$E mkproc 601 600 /w/p 5000 opencode pair
pane 0 100 "opencode.exe"; pane 1 200 "opencode mini --model x"; pane 2 300 "opencode mini"
pane 3 400 "opencode --server http://localhost:4096"; pane 4 500 "opencode service status"; pane 5 600 "opencode pair"
run
check "opencode: 2.x session_v2"                 "TMUX_RESTORE=1 opencode -s ses_V2"                    "${GOT[0]}"
check "opencode: mini comes back as mini"        "TMUX_RESTORE=1 opencode mini -s ses_M1 --model x"     "${GOT[1]}"
check "opencode: mini, nothing yet -> mini -c"   "TMUX_RESTORE=1 opencode mini -c"                      "${GOT[2]}"
check "opencode: --server keeps its URL"         "TMUX_RESTORE=1 opencode -s ses_S1 --server http://localhost:4096" "${GOT[3]}"
check "opencode: 'service' isn't the TUI"        "TMUX_RESTORE=1 print -rz -- 'opencode service status'" "${GOT[4]}"
check "opencode: 'pair' isn't the TUI"           "TMUX_RESTORE=1 print -rz -- 'opencode pair'"          "${GOT[5]}"

# --- pi ---------------------------------------------------------------------------------------
reset
mkdir -p "$D/pi/sessions/--w-a--" "$D/pi/sessions/--w-b--"
f1="$D/pi/sessions/--w-a--/2023-11-14T22-15-00-000Z_1111.jsonl"; setmtime "$f1" 1700000100
setmtime "$D/pi/sessions/--w-a--/2023-11-14T22-00-00-000Z_0000.jsonl" 1700000010
setmtime "$D/pi/sessions/--w-b--/2023-11-14T22-00-00-000Z_2222.jsonl" 1700000010
E="PI_CODING_AGENT_DIR=$D/pi"
mkproc 100 1 /w/a 10 /usr/bin/zsh; EXE=/opt/node/bin/node ENVIRON=$E mkproc 101 100 /w/a 5000 pi
mkproc 200 1 /w/b 10 /usr/bin/zsh; EXE=/opt/node/bin/node ENVIRON=$E mkproc 201 200 /w/b 5000 pi
mkproc 300 1 /w/c 10 /usr/bin/zsh; mkproc 301 300 /w/c 5000 pi 1000
pane 0 100 "pi"; pane 1 200 "pi"; pane 2 300 "pi 1000"
run
check "pi: session written since it started"     "TMUX_RESTORE=1 pi --session $f1"                      "${GOT[0]}"
check "pi: nothing written yet -> -c"            "TMUX_RESTORE=1 pi -c"                                 "${GOT[1]}"
check "pi: Debian's pi isn't the agent"          "TMUX_RESTORE=1 print -rz -- 'pi 1000'"                "${GOT[2]}"

# --- Codex ------------------------------------------------------------------------------------
reset
rollout() { # FILE SOURCE THREAD_SOURCE CWD: a rollout file's first line
	mkdir -p "$(dirname "$1")"
	printf '{"type":"session_meta","payload":{"id":"x","cwd":"%s","source":%s,"thread_source":"%s","base_instructions":"..."}}\n' "$4" "$2" "$3" > "$1"
}
R=$D/codex/sessions/2026/10/31
u1=11111111-2222-3333-4444-555555555555 u2=66666666-7777-8888-9999-aaaaaaaaaaaa
rollout "$R/rollout-2026-10-31T10-00-00-$u1.jsonl" '"cli"' user /w/a
rollout "$R/rollout-2026-10-31T10-05-00-$u2.jsonl" '{"subagent":"review"}' subagent /w/a
setmtime "$R/rollout-2026-10-31T10-00-00-$u1.jsonl" 1700000100; setmtime "$R/rollout-2026-10-31T10-05-00-$u2.jsonl" 1700000200
mkproc 100 1 /w/a 10 /usr/bin/zsh
EXE=/opt/node/bin/node mkproc 101 100 /w/a 5000 MainThread; printf '%s\0' node /opt/codex/bin/codex --model gpt-5 'fix it' > "$TMUX_RESTORE_PROC/101/cmdline"
mkproc 102 101 /w/a 5000 /opt/codex/native/codex --model gpt-5 'fix it'
openfile 102 "$R/rollout-2026-10-31T10-00-00-$u1.jsonl"; openfile 102 "$R/rollout-2026-10-31T10-05-00-$u2.jsonl"
u3=cccccccc-dddd-eeee-ffff-000000000000; rollout "$R/rollout-2026-10-31T11-00-00-$u3.jsonl" '"cli"' user /w/x
mkproc 200 1 /w/b 10 /usr/bin/zsh; mkproc 201 200 /w/b 5000 codex -C /w/x resume "$u3"; openfile 201 "$R/rollout-2026-10-31T11-00-00-$u3.jsonl"
mkproc 300 1 /w/c 10 /usr/bin/zsh; mkproc 301 300 /w/c 5000 codex -m o3
mkproc 400 1 /w/d 10 /usr/bin/zsh; mkproc 401 400 /w/d 5000 codex exec 'do x'
pane 0 100 "node /opt/codex/bin/codex --model gpt-5 fix it"; pane 1 200 "codex -C /w/x resume $u3"
pane 2 300 "codex -m o3"; pane 3 400 "codex exec do x"
run
check "codex: node wrapper -> native's rollout"  "TMUX_RESTORE=1 codex resume $u1 -C /w/a --model gpt-5" "${GOT[0]}"
check "codex: keeps its own -C"                   "TMUX_RESTORE=1 codex resume $u3 -C /w/x"              "${GOT[1]}"
check "codex: nothing typed yet -> fresh"         "TMUX_RESTORE=1 codex -m o3"                           "${GOT[2]}"
check "codex: exec isn't the TUI"                 "TMUX_RESTORE=1 print -rz -- 'codex exec do x'"        "${GOT[3]}"

# --- Gemini -----------------------------------------------------------------------------------
reset
G=$D/ghome/.gemini; mkdir -p "$G/tmp/w-a/chats" "$G/tmp/w-b/chats"
printf '{"projects":{"/w/a":"w-a","/w/b":"w-b"}}\n' > "$G/projects.json"
gsession() { # FILE ID START TYPED: a session file
	printf '{"sessionId":"%s","projectHash":"h","startTime":"%s","lastUpdated":"%s","kind":"main"}\n' "$2" "$3" "$3" > "$1"
	printf '{"id":"d04923d38bb0f6017037e74183378ef4","timestamp":"%s","type":"user","content":"env"}\n' "$3" >> "$1"
	[[ $4 == typed ]] && printf '{"id":"m1","timestamp":"%s","type":"user","content":"hi"}\n' "$3" >> "$1"
	return 0
}
g1=aaaaaaaa-0000-0000-0000-000000000001 g0=aaaaaaaa-0000-0000-0000-000000000000 g2=bbbbbbbb-0000-0000-0000-000000000002
gsession "$G/tmp/w-a/chats/session-2023-11-14T22-14-aaaaaaaa.jsonl" "$g1" 2023-11-14T22:14:12.000Z typed    # after start
gsession "$G/tmp/w-a/chats/session-2023-11-14T22-00-aaaaaaa0.jsonl" "$g0" 2023-11-14T22:00:00.000Z typed    # before
gsession "$G/tmp/w-b/chats/session-2023-11-14T22-14-bbbbbbbb.jsonl" "$g2" 2023-11-14T22:14:12.000Z untyped
E="GEMINI_CLI_HOME=$D/ghome"
gemini_pane() { # PANE_PID CWD ARGS...: shell -> launcher -> relaunched TUI
	local pane=$1 cwd=$2; shift 2
	mkproc "$pane" 1 "$cwd" 10 /usr/bin/zsh
	EXE=/opt/node/bin/node ENVIRON=$E mkproc $((pane + 1)) "$pane" "$cwd" 4900 MainThread
	printf '%s\0' node /opt/g/bin/gemini "$@" > "$TMUX_RESTORE_PROC/$((pane + 1))/cmdline"
	EXE=/opt/node/bin/node ENVIRON=$E mkproc $((pane + 2)) $((pane + 1)) "$cwd" 5000 MainThread
	printf '%s\0' /opt/node/bin/node --max-old-space-size=99 /opt/g/bin/gemini "$@" > "$TMUX_RESTORE_PROC/$((pane + 2))/cmdline"
}
gemini_pane 100 /w/a -m pro; gemini_pane 200 /w/b -m pro; gemini_pane 300 /w/c --resume "$g0"; gemini_pane 400 /w/d -p 'do x'
EXE=/opt/node/bin/node mkproc 900 1 /w/a 10 MainThread; printf '%s\0' node server.js > "$TMUX_RESTORE_PROC/900/cmdline" # unrelated node
mkdir -p "$G/tmp/w-e/chats"; jq '.projects["/w/e"] = "w-e"' "$G/projects.json" > "$G/p.json" && mv "$G/p.json" "$G/projects.json"
gsession "$G/tmp/w-e/chats/session-2023-11-14T22-14-eeeeeee1.jsonl" eeeeeeee-0000-0000-0000-000000000001 2023-11-14T22:14:12.000Z typed
gemini_pane 500 /w/e; gemini_pane 600 /w/e # two in one directory
pane 0 100 "node /opt/g/bin/gemini -m pro"; pane 1 200 "node /opt/g/bin/gemini -m pro"
pane 2 300 "node /opt/g/bin/gemini --resume $g0"; pane 3 400 "node /opt/g/bin/gemini -p do x"
pane 4 500 "node /opt/g/bin/gemini"; pane 5 600 "node /opt/g/bin/gemini"
run
check "gemini: session started since, typed in"  "TMUX_RESTORE=1 gemini --resume $g1 -m pro"            "${GOT[0]}"
check "gemini: nothing typed yet -> fresh"        "TMUX_RESTORE=1 gemini -m pro"                         "${GOT[1]}"
check "gemini: the session it was resumed with"   "TMUX_RESTORE=1 gemini --resume $g0"                   "${GOT[2]}"
check "gemini: two in one dir -> typed"         "TMUX_RESTORE=1 print -rz -- 'node /opt/g/bin/gemini'" "${GOT[4]}"
check "gemini: two in one dir -> typed (2)"     "TMUX_RESTORE=1 print -rz -- 'node /opt/g/bin/gemini'" "${GOT[5]}"
check "gemini: headless -p isn't the TUI"         "TMUX_RESTORE=1 print -rz -- 'node /opt/g/bin/gemini -p do x'" "${GOT[3]}"

# --- ai-memory wrapper ------------------------------------------------------------------------
reset
mkdir -p "$D/data/opencode"
sqlite3 "$D/data/opencode/opencode.db" "CREATE TABLE session (id TEXT, parent_id TEXT, directory TEXT, time_updated INTEGER);
	INSERT INTO session VALUES ('ses_W1', NULL, '/w/a', 1700000100000);"
E="XDG_DATA_HOME=$D/data"
mkproc 100 1 /w/a 10 /usr/bin/zsh
ENVIRON=$E mkproc 101 100 /w/a 5000 /usr/local/bin/ai-memory run opencode --yolo --continue
ENVIRON=$E mkproc 102 101 /w/a 5000 /opt/opencode/bin/opencode.exe --continue --auto
pane 0 100 "ai-memory run opencode --yolo --continue"
run
check "ai-memory: opencode child resumes"        "TMUX_RESTORE=1 ai-memory run opencode -s ses_W1 --auto" "${GOT[0]}"

reset
mkproc 100 1 /w/a 10 /usr/bin/zsh
mkproc 101 100 /w/a 5000 /usr/local/bin/ai-memory run claude --model opus
mkproc 102 101 /w/a 5000 claude --model opus
claude_registry 102 S1 5000
pane 0 100 "ai-memory run claude --model opus"
run
check "ai-memory: claude child resumes"          "TMUX_RESTORE=1 ai-memory run claude --resume S1 --model opus" "${GOT[0]}"

reset
mkdir -p "$D/data/opencode"
sqlite3 "$D/data/opencode/opencode.db" "CREATE TABLE session (id TEXT, parent_id TEXT, directory TEXT, time_updated INTEGER);"
mkproc 100 1 /w/a 10 /usr/bin/zsh
ENVIRON=$E mkproc 101 100 /w/a 5000 /usr/local/bin/ai-memory run opencode --yolo --continue
ENVIRON=$E mkproc 102 101 /w/a 5000 /opt/opencode/bin/opencode.exe --continue --auto
pane 0 100 "ai-memory run opencode --yolo --continue"
run
check "ai-memory: nothing written yet -> -c"     "TMUX_RESTORE=1 ai-memory run opencode -c --auto" "${GOT[0]}"

reset
mkproc 100 1 /w/a 10 /usr/bin/zsh
mkproc 101 100 /w/a 5000 /usr/local/bin/ai-memory status
pane 0 100 "ai-memory status"
run
check "ai-memory: not 'run' isn't the TUI"       "TMUX_RESTORE=1 print -rz -- 'ai-memory status'" "${GOT[0]}"

# --- your own adapter, and a hook you already had --------------------------------------------
reset
mkdir -p "$XDG_CONFIG_HOME/tmux-restore/agents"
cat > "$XDG_CONFIG_HOME/tmux-restore/agents/fakeagent.sh" <<'EOF'
fakeagent_match() { [[ $(proc_name "$1") == fakeagent ]]; }
fakeagent_session() { echo F1; }
fakeagent_resume() { proc_args "$1"; printf 'fakeagent --open %s%s' "$2" "$(keep_flags fakeagent "${ARGV[@]}")"; }
fakeagent_value_flags="--model"
EOF
printf '#!/bin/sh\necho "$1" > "%s/next.log"\n' "$D" > "$D/next-hook.sh"; chmod +x "$D/next-hook.sh"
mkproc 100 1 /w 10 /usr/bin/zsh; mkproc 101 100 /w 5000 node /opt/fake/bin/fakeagent.js --model big 'a prompt'
pane 0 100 "node /opt/fake/bin/fakeagent.js --model big a prompt"
NEXT_HOOK="$D/next-hook.sh" run
check "own adapter (node script, flags kept)"  "TMUX_RESTORE=1 fakeagent --open F1 --model big"    "${GOT[0]}"
check "hook you had runs after, with the file" "$D/save"                                           "$(cat "$D/next.log" 2>/dev/null)"

echo "passed=$pass failed=$fail"; (( fail == 0 ))
