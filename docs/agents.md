# Agents

Each pane running a coding agent comes back on the conversation it was in, with the flags it was
started with. The initial prompt is never sent again.

| Agent | How tmux-restore finds the conversation | Restored as | Verified with |
|---|---|---|---|
| [Claude Code](https://claude.com/claude-code) | Claude Code's registry of running sessions (`~/.claude/sessions/<pid>.json`). Exact, and it follows `/clear`. | `claude --resume <id> <flags>` | 2.1.316 |
| [Codex CLI](https://github.com/openai/codex) | The rollout file Codex keeps open (`~/.codex/sessions/…/rollout-…-<id>.jsonl`). Exact. | `codex resume <id> -C <dir> <flags>` | 0.134.0 |
| [Gemini CLI](https://github.com/google-gemini/gemini-cli) | The newest session of the pane's project that started after the agent did and that you typed in. | `gemini --resume <id> <flags>` | 0.66.0 |
| [opencode](https://opencode.ai) | The newest session in the agent's directory updated after it started. | `opencode -s <id> <flags>` | 2.2.6 |
| [pi](https://github.com/badlogic/pi-mono) | The newest session file in the agent's directory written after it started. | `pi --session <file>` | 0.55.0 |
| [ai-memory](https://github.com/akitaonrails/ai-memory) | The harness child it launches (`ai-memory run opencode`, `... claude`, ...); delegates to that harness's adapter. | `ai-memory run <harness> <same resume command>` | 3.4.3 |

**Wrappers.** A pane running `ai-memory run <harness>` is recognized: the adapter finds the harness
child and wraps its resume command in `ai-memory run <harness> ...`, so ai-memory's hooks and MCP
stay in the loop.

"Verified" means a real round trip on a throwaway tmux server on Linux: the agent ran in a pane
with a conversation, tmux saved, the server was killed and restored, and the same conversation
reopened. On macOS, the same lookups run through `ps` and `lsof`, and CI checks them against real
processes.

**Nothing typed yet.** A session you haven't typed in yet comes back fresh: Claude Code with the
same session id, Codex and Gemini CLI as a new session. opencode and pi come back with `-c`, their
latest conversation in that directory.

**Two of the same agent in one directory.** Gemini CLI, opencode and pi don't record which
process has which conversation open, so tmux-restore tells them apart by directory and start
time. When two panes run the same one of these in the same directory, it can't, so both come
back as commands typed on the prompt (see [caveats](caveats.md)). Claude Code and Codex are
always exact.

**Flags.** Flags that pick a conversation (`--continue`, `--resume`, `-s`, ...) are replaced.
pi hides its command line, so its flags can't be kept.

## Another agent

An adapter is one short file in [`agents/`](../agents); see [CONTRIBUTING.md](../CONTRIBUTING.md).
You can keep your own in `~/.config/tmux-restore/agents/`.
