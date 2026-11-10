#!/usr/bin/env bash
# Unit tests for scripts/save-hook.sh and scripts/lib.sh: flag filtering, quoting, prefill, and
# which saved commands get rewritten (on a throwaway tmux server). Needs zsh.
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/save-hook.sh
source "$here/../scripts/save-hook.sh"
load_agents
pass=0 fail=0
check() { if [[ $2 == "$3" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL %s\n  want: [%s]\n  got:  [%s]\n' "$1" "$2" "$3"; fi; }
ka() { keep_flags claude "$@"; }
check "flags kept"           " --dangerously-skip-permissions --effort max" "$(ka --dangerously-skip-permissions --effort max)"
check "prompt dropped"       " --dangerously-skip-permissions"              "$(ka --dangerously-skip-permissions 'fix the bug')"
check "prompt between flags" " --model opus --effort high"                  "$(ka --model opus 'do x' --effort high)"
check "-c dropped"           " --dangerously-skip-permissions"              "$(ka -c --dangerously-skip-permissions)"
check "--resume id dropped"  " --effort max"                                "$(ka --resume abc-123 --effort max)"
check "-r w/o value dropped" " --effort max"                                "$(ka -r --effort max)"
check "= forms"              " --model=sonnet"                              "$(ka --resume=abc --model=sonnet)"
check "session-id/fork drop" " --name my\\ session"                         "$(ka --session-id 1111 --fork-session --name 'my session')"
check "variadic then prompt" " --add-dir /a /b --model x"                   "$(ka --add-dir /a /b --model x prompt words)"
check "optional value"       " --debug api"                                 "$(ka --debug api hello)"
check "-- ends options"      ""                                             "$(ka -- 'prompt')"
check "no args"              ""                                             "$(ka)"
quoted=$(ka --append-system-prompt "be terse; it's \$fine" --effort max "a prompt"); eval "set -- $quoted"
check "roundtrip argc" "4" "$#"; check "roundtrip value" "be terse; it's \$fine" "$2"
pid=$(for p in $(pgrep -x claude); do [[ -e ~/.claude/sessions/$p.json ]] && { echo "$p"; break; }; done)
[[ -n $pid ]] && check "proc_start vs registry" "$(jq -r .procStart ~/.claude/sessions/"$pid".json)" "$(proc_start "$pid")"
for cmd in 'sleep 100000' "python3 -c import\\ time\;\\ time.sleep\\(1e6\\) it\\'s\\ a\\ test" "echo \$'a\\nb' \"double\" 'single'" 'grep -r foo\ bar . | wc -l'; do
	check "prefill: $cmd" "$cmd" "$(zsh -fc "$(prefill "$cmd"); read -rz got; print -rn -- \$got")"
done

# main(): an unsafe command becomes a pre-typed prompt only when restored panes run zsh
tmux() { command tmux -L hook-unit "$@"; }
D=$(mktemp -d); trap 'command tmux -L hook-unit kill-server 2>/dev/null; rm -rf "$D" "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/hook-unit"' EXIT
command tmux -L hook-unit -f /dev/null new-session -d
for shell in zsh bash; do
	tmux set -g default-shell "$(command -v "$shell")"
	printf 'pane\tmain\t0\t1\t:*\t%s\tzsh\t:/tmp\t1\t%s\t:%s\n' 0 make 'make deploy' 1 vim 'vim notes.txt' > "$D/save"
	main "$D/save"
	[[ $shell == zsh ]] && want=":TMUX_RESTORE=1 print -rz -- 'make deploy'" || want=":make deploy"
	check "main ($shell): unsafe" "$want" "$(sed -n 1p "$D/save" | cut -f11)"
	check "main ($shell): safe" ":vim notes.txt" "$(sed -n 2p "$D/save" | cut -f11)"
done
# a program that renamed itself: resurrect records "npm\ run\ dev '' '' ''"
tmux set -g default-shell "$(command -v zsh)"
printf 'pane\tmain\t0\t1\t:*\t0\tzsh\t:/tmp\t1\tnpm\t:%s\n' "npm\\ run\\ dev '' '' '' " > "$D/save"
main "$D/save"
check "renamed process: typed as its name" ":TMUX_RESTORE=1 print -rz -- 'npm run dev'" "$(cut -f11 "$D/save")"
check "tidy leaves real arguments alone" "grep -r foo\\ bar ." "$(tidy "grep -r foo\\ bar .")"
# a program you list in @resurrect-processes is left as it is, for resurrect to run again
tmux set -g @resurrect-processes 'my-agent'
printf 'pane\tmain\t0\t1\t:*\t0\tzsh\t:/tmp\t1\tmy-agent\t:%s\n' 'my-agent --resume-last' > "$D/save"
main "$D/save"
check "@resurrect-processes: left as it is" ":my-agent --resume-last" "$(cut -f11 "$D/save")"
# ...matched by resurrect's own rules: "a b" matches commands that start with "a b", "x->y" matches
# x, and "~x->y" matches x anywhere. A plain "~pattern" still comes back typed.
tmux set -g @resurrect-processes '"btop->btop --utf-force" "git log" "~rails server->rails server *" "~npm run dev"'
printf 'pane\tmain\t0\t1\t:*\t%s\tzsh\t:/tmp\t1\t%s\t:%s\n' 0 btop btop 1 git 'git log --oneline' 2 git 'git push' \
	3 topgrade topgrade 4 bundle 'bundle exec rails server -p 3001' 5 npm 'npm run dev' > "$D/save"
main "$D/save"
got() { sed -n "$1p" "$D/save" | cut -f11; }
check "@resurrect-processes: x->y matches x"            ":btop"                                   "$(got 1)"
check "@resurrect-processes: \"git log\" matches"       ":git log --oneline"                      "$(got 2)"
check "@resurrect-processes: \"git log\" isn't all git" ":TMUX_RESTORE=1 print -rz -- 'git push'" "$(got 3)"
check "@resurrect-processes: top isn't topgrade"      ":TMUX_RESTORE=1 print -rz -- 'topgrade'" "$(got 4)"
check "@resurrect-processes: ~x->y left for resurrect"  ":bundle exec rails server -p 3001"       "$(got 5)"
check "@resurrect-processes: plain ~pattern typed"      ":TMUX_RESTORE=1 print -rz -- 'npm run dev'" "$(got 6)"
# a program you list wins over tmux-restore's own: left as it is, for resurrect to run
tmux set -g @resurrect-processes '"journalctl -f"'
printf 'pane\tmain\t0\t1\t:*\t0\tzsh\t:/tmp\t1\tjournalctl\t:%s\n' 'journalctl -f -u nginx' > "$D/save"
main "$D/save"
check "@resurrect-processes: wins over restartable" ":journalctl -f -u nginx" "$(got 1)"
tmux set -g @resurrect-processes ''
# monitors and commands that follow logs restart with any shell, though resurrect doesn't list
# them; commands that only look like them don't
restarts=('nvtop' 'iotop -o' 'nethogs wlan0' 'journalctl -f' 'journalctl -fu nginx' 'journalctl -u nginx -f'
	'journalctl -xef' 'journalctl --follow -n 50' 'journalctl -u my\ unit -f' 'docker logs -f web'
	'docker logs web --follow' 'docker logs -tf web' 'docker compose logs -f' 'docker-compose logs -f api'
	'kubectl logs -f deploy/api' 'kubectl logs api-0 -n prod -f')
not_restarted=('kubectl apply -f x.yaml' 'kubectl delete -f x.yaml' 'kubectl -n logs delete -f x.yaml'
	'kubectl -n prod logs -f api' 'docker rm -f web' 'docker compose -f prod.yml up' 'journalctl --vacuum-size=1G'
	'journalctl -u nginx' 'journalctl -F _SYSTEMD_UNIT' 'journalctl-upload -f' 'sudo iotop' 'nvtopx' 'make -f ci.mk')
for shell in zsh bash; do
	tmux set -g default-shell "$(command -v "$shell")"
	n=0
	for cmd in "${restarts[@]}" "${not_restarted[@]}"; do
		printf 'pane\tmain\t0\t1\t:*\t%s\tzsh\t:/tmp\t1\t%s\t:%s\n' "$n" "${cmd%% *}" "$cmd"
		n=$((n + 1))
	done > "$D/save"
	main "$D/save"
	n=0
	for cmd in "${restarts[@]}"; do
		n=$((n + 1))
		check "restarts ($shell): $cmd" ":TMUX_RESTORE=1 $cmd" "$(got $n)"
	done
	for cmd in "${not_restarted[@]}"; do
		n=$((n + 1))
		[[ $shell == zsh ]] && want=":TMUX_RESTORE=1 $(prefill "$cmd")" || want=":$cmd"
		check "not restarted ($shell): $cmd" "$want" "$(got $n)"
	done
done
tmux set -g default-shell "$(command -v zsh)"
# the save folder also holds every pane's scrollback, so the hook makes it private
mkdir -m 755 "$D/resurrect"
printf 'pane\tmain\t0\t1\t:*\t0\tzsh\t:/tmp\t1\tzsh\t:\n' > "$D/resurrect/save"
main "$D/resurrect/save"
check "save folder: private" "$D/resurrect" "$(find "$D/resurrect" -maxdepth 0 -perm 700)"
# the venv a pane has active is a pane option (scripts/shell-hook.sh sets it)
mkdir -p "$D/venv/bin" && : > "$D/venv/bin/activate"
target=$(tmux list-panes -F '#{session_name}	#{window_index}	#{pane_index}' | head -1)
tmux set-option -p -t "$(printf '%s:%s.%s' $target)" @tmux-restore-venv "$D/venv"
printf 'pane\t%s\t%s\t1\t:*\t%s\tzsh\t:/tmp\t1\tzsh\t:\n' $target > "$D/save"
main "$D/save"
check "venv: read from the pane option" ":TMUX_RESTORE=1 . '$D/venv/bin/activate' 2> /dev/null" "$(cut -f11 "$D/save")"
echo "passed=$pass failed=$fail"; (( fail == 0 ))
