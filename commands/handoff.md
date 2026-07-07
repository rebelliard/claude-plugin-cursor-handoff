---
description: Send a well-scoped task to the Cursor CLI and review the result
argument-hint: <task description> [--worktree] [--background] [--model <id>]
---

Send the following task to the Cursor CLI, then review and iterate on the result.

Task: $ARGUMENTS

Follow the plugin's `cursor-handoff` skill (read `${CLAUDE_PLUGIN_ROOT}/skills/cursor-handoff/SKILL.md` if not already loaded) exactly:

0. Before writing a prompt or gathering extra context, run `${CLAUDE_PLUGIN_ROOT}/scripts/cursor-run.sh auth`. If it reports `not authenticated`, stop and tell the user to run `cursor-agent login` in a local terminal and complete the browser flow, or export `CURSOR_API_KEY`.
1. If this is really several tasks, or you intend to keep working while it runs, delegate the management too: spawn a `handoff-manager` subagent per the skill's orchestration section instead of babysitting inline. Continue below only for a single task you will wait on.
2. If the task above is too vague to hand to Cursor as-is, gather only the minimum repo context needed to make the instruction self-contained — the executor gets no conversation context.
3. Decide run flags: honor `--worktree`, `--model`, and `--background` (Bash run_in_background) if present in the arguments; default to `--worktree` whenever the tree is dirty or you will keep working during the run.
4. Run `${CLAUDE_PLUGIN_ROOT}/scripts/cursor-run.sh new <flags> --prompt "<self-contained instruction>"`. Keep the prompt compact: the user's request plus any essential file hints or verification, followed by `Do not commit, stage, or push unless explicitly asked. Report changed files and verification output.`
5. Use a scratch prompt file only when shell quoting would make `--prompt` awkward (large pasted instructions, multiline user-provided text, or long verification commands). Do not expand the user's request into a formal document unless orchestration/manager mode needs a structured task contract.
6. When it finishes: review the diff, run the verification commands yourself, and iterate via `cursor-run.sh continue <CHAT_ID> ...` with pointed feedback if needed (one round, then take over).
7. Report: what was sent to Cursor, what came back, verification results, and the CHAT_ID for future resumes.
