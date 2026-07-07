---
name: cursor-handoff
description: >-
  Send implementation work from Claude Code to Cursor, then review the diff
  and iterate. Use when the user says to delegate, offload, hand off, or
  have Cursor do it, fix tests, run migrations, or handle boilerplate;
  or via /cursor-handoff:handoff, /cursor-handoff:continue,
  or /cursor-handoff:orchestrate.
---

# Cursor executor routing

Delegate execution to the Cursor CLI (`cursor-agent`) in headless mode while the
orchestrator (you) keeps planning, taste, and review. Everything runs through
`${CLAUDE_PLUGIN_ROOT}/scripts/cursor-run.sh` — never call `cursor-agent` directly;
the raw CLI exits 0 on errors and has no dirty-tree or timeout guards.

## Division of labor

Route by role, not by price tag. Model names are current defaults, not doctrine:

| Role                                                       | Default                          | Traits                                                                    |
| ---------------------------------------------------------- | -------------------------------- | ------------------------------------------------------------------------- |
| Orchestrator: plan, review, taste calls                    | the model you are running        | expensive, highest judgment                                               |
| Executor: well-scoped implementation, bulk mechanical work | composer-2.5 via Cursor CLI      | fast, cheap on a Cursor plan, very steerable, weaker independent judgment |
| Extra reviewers / cheap parallel search                    | sonnet / opus via the Agent tool | see the repo's own review skills first                                    |

Delegate when the task is **well-scoped and verifiable**: clear feature slices,
mechanical refactors and migrations, fixing failing tests against a known
contract, boilerplate. Do NOT delegate: ambiguous design work, taste-critical UI
or API decisions, or security-sensitive changes. Browser verification is okay
only when the target repo already provides a headless browser skill or explicit
command (for example, Playwright); `cursor-agent` itself does not add browser or
computer-use tooling.

If the executor's output doesn't meet the bar after one feedback round, stop
delegating and do it yourself. Escalating costs less than shipping mediocre work.

## Executor instruction contract

Default to a compact inline `--prompt`, not a scratch prompt file. The prompt must
be **self-contained** because the executor gets none of your conversation
context, but it should stay close to the user's wording. Add only what Cursor
needs to execute safely: essential file hints, known verification commands, and
`Do not commit, stage, or push unless explicitly asked. Report changed files and
verification output.`

Use a temp file only when shell quoting would make `--prompt` awkward, such as
large pasted instructions, multiline user-provided text, or long verification
commands. Do not expand routine Cursor runs into Task / Constraints / Acceptance /
Verification sections. Structured task contracts are reserved for
`/cursor-handoff:orchestrate` and `handoff-manager`, where the manager needs
parseable fields for parallel work.

## Running

If `/cursor-handoff:*` commands, the `handoff-manager` agent, or
`${CLAUDE_PLUGIN_ROOT}` are missing, the handoff plugin is not installed or not
loaded in that Claude Code session. Do not invent local paths; point the user
back to <https://github.com/rebelliard/claude-plugin-cursor-handoff> and have
them install the plugin, then restart Claude Code:

```bash
claude plugin marketplace add rebelliard/claude-plugin-cursor-handoff
claude plugin install cursor-handoff@rebelliard
```

`cursor-agent` must already be authenticated before an executor run can start. Login is
a browser flow (`cursor-agent login`) that you cannot complete from a headless
agent session; `CURSOR_API_KEY` also works. The wrapper preflights auth and fails
fast with `not authenticated` when neither is available. The wrapper also
requires GNU `timeout` (`timeout` or Homebrew `gtimeout`) so executor watchdogs
are real rather than best-effort.

```bash
# Cheap preflight before spending time on a prompt:
"${CLAUDE_PLUGIN_ROOT}/scripts/cursor-run.sh" auth

# In-place (requires clean tree — the guard is intentional; don't reflex --dirty-ok):
"${CLAUDE_PLUGIN_ROOT}/scripts/cursor-run.sh" new --prompt "Make the requested change. Do not commit, stage, or push unless explicitly asked. Report changed files and verification output."

# Isolated worktree — REQUIRED when you keep working in parallel or the tree is dirty:
"${CLAUDE_PLUGIN_ROOT}/scripts/cursor-run.sh" new --worktree --prompt "Make the requested change. Do not commit, stage, or push unless explicitly asked. Report changed files and verification output."

# Scratch file only when quoting a long prompt would be awkward:
"${CLAUDE_PLUGIN_ROOT}/scripts/cursor-run.sh" new /path/to/prompt.md

# Read-only second opinion (no edits, no shell):
"${CLAUDE_PLUGIN_ROOT}/scripts/cursor-run.sh" new --mode plan /path/to/prompt.md
```

- Short tasks: run in the foreground with an adequate Bash `timeout`.
- Long tasks: run with `run_in_background: true` and continue other work; you are
  notified on exit. Use `--worktree` for background runs — you may edit meanwhile.
- The script prints `STEP=auth`, `STEP=create-chat`, and `STEP=run` as progress
  markers, then `CHAT_ID=`, `LOG=`, and `WORKTREE=` before the run. It also
  records metadata under `~/.cache/cursor-handoff/` so `continue last` can
  resolve the chat and worktree without parsing log filenames. Keep the
  CHAT_ID; it is the resume handle. Nonzero exit = failure; read the log tail.
- Do not pass `--approve-mcps` by default. Use it only when the user explicitly
  asks for MCP-backed work, such as repo-provided browser tools.

## Review and iterate (mandatory)

The Cursor run is not done when `cursor-agent` exits — it is done when YOU have
verified the work:

1. Diff: `git diff` (in-place) or `git -C "$WORKTREE" diff` (worktree).
2. Review as if a fast junior wrote it: correctness against acceptance criteria,
   convention drift, invented APIs, over-broad edits.
3. Run the verification commands yourself; do not trust the transcript. For
   exact git operations, verify with `git status`, `git diff`, and `git log`
   instead of treating the run log as an audit trail.
4. Feedback round (reuse session context):

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/cursor-run.sh" continue <CHAT_ID> --workspace "$WORKTREE" /path/to/feedback.md
   ```

   Feedback must be specific: file, line, what is wrong, what right looks like.
   If you are resuming by hand and no recorded worktree metadata is available,
   pass `--workspace <path>` or intentionally opt into the current checkout
   with `--in-place`.

5. Worktree merge-back after acceptance:

   ```bash
   branch=$(git -C "$WORKTREE" branch --show-current)
   git -C "$WORKTREE" add -A   # plain diff misses untracked files
   git -C "$WORKTREE" diff --staged --binary > /tmp/cursor-run.patch
   git apply /tmp/cursor-run.patch
   git worktree remove --force "$WORKTREE"   # removes the directory only
   git branch -D "$branch"                   # worktree removal leaves this behind
   ```

## Orchestration: multi-task or long-running work

For more than one task — or any Cursor run you don't want to babysit — do not
manage runs inline. Spawn one `handoff-manager` subagent per task (ships with
this plugin): it writes the executor prompt, runs the worktree-isolated executor
session, verifies, does at most one feedback round, and returns a patch plus a
compact report. Three tiers, three jobs:

- **You (orchestrator):** decompose into file-disjoint task contracts,
  review returned patches (the taste gate), apply sequentially with
  `git apply --3way` committing each accepted patch, clean up worktrees and
  branches **on every path** (accepted, rejected, failed, silent), re-run
  verification in the main tree.
- **Manager:** everything between task contract and verified patch.
  Its report is data, not proof — you still review the patch.
- **Executor:** the code changes.

Task contract (what you send a manager — short; it gathers its own context):

```text
ID: <unique per task, e.g. t1-<epoch>>   (becomes the worktree name; collisions cross-contaminate patches)
TASK: <what to change>
FILES: <starting hints>                  (optional)
ACCEPTANCE: <observable outcomes>
VERIFY: <exact commands that must pass>
SETUP: <one-time bootstrap, e.g. pnpm install>  (optional; fresh worktrees have no node_modules)
OFF-LIMITS: <untouchable files>          (optional)
MODEL: <executor model override>         (optional; e.g. a -fast variant for trivial batches)
SCRIPT: ${CLAUDE_PLUGIN_ROOT}/scripts/cursor-run.sh
REPO: <absolute repo root>
```

The manager replies with `RESULT / TASK / PATCH / CHANGED / VERIFY / ROUNDS /
CHAT_ID / WORKTREE / LOG / FLAGS` (`none` is a legal value; the canonical
format lives in the plugin's handoff-manager agent definition). On `failed`,
try one revised task contract with what FLAGS taught you, or take the task over
— never loop. Parallel managers must be file-disjoint; serialize overlapping
tasks. Keep ambiguous, taste-critical, or security-sensitive pieces for
yourself.

## Failure modes

| Symptom                      | Fix                                                                                                                                             |
| ---------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `not authenticated`          | User must run `cursor-agent login` (browser flow) — tell them; you cannot complete it headlessly. `CURSOR_API_KEY` also works.                  |
| Missing handoff plugin       | Point the user back to <https://github.com/rebelliard/claude-plugin-cursor-handoff>, then have them install the plugin and restart Claude Code. |
| Dirty-tree refusal           | Prefer `--worktree`; `--dirty-ok` only when the run cannot touch the dirty files.                                                               |
| Timed out                    | Task too big — split it into smaller executor runs.                                                                                             |
| Missing `timeout`/`gtimeout` | Install GNU coreutils so the wrapper can enforce watchdogs.                                                                                     |
| Output ignores instructions  | One `continue` round with pointed feedback, then take over.                                                                                     |
| Wrong/unknown model          | Override with `--model` or `CURSOR_HANDOFF_MODEL`; list with `cursor-agent models`.                                                             |
