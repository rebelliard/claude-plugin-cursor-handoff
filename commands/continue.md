---
description: Send feedback to a previous Cursor session and re-review
argument-hint: <chat-id or "last"> <feedback / follow-up instructions>
---

Continue a previous Cursor executor session with feedback.

Arguments: $ARGUMENTS

1. Before writing feedback, run `${CLAUDE_PLUGIN_ROOT}/scripts/cursor-run.sh auth`. If it reports `not authenticated`, stop and tell the user to run `cursor-agent login` in a local terminal and complete the browser flow, or export `CURSOR_API_KEY`.
2. Resolve the chat id: if "last" or omitted, use the most recent CHAT_ID from this conversation. If that is unavailable, use `${XDG_CACHE_HOME:-$HOME/.cache}/cursor-handoff/latest.env`; do **not** infer the chat id from log filenames. If the metadata includes `WORKTREE`, resume with that workspace.
3. Send compact, self-contained feedback with `${CLAUDE_PLUGIN_ROOT}/scripts/cursor-run.sh continue <chat-id-or-last> --workspace <worktree-path> --prompt "<feedback>"`. For an original in-place run with no worktree metadata, pass `--in-place` intentionally instead of omitting a target. Include the file/behavior to fix, what right looks like, and `Do not commit, stage, or push unless explicitly asked.`
4. Use a scratch feedback file only when shell quoting would make `--prompt` awkward.
5. Review the new diff and verify. If it still misses, take over and finish the work yourself instead of looping.
