# claude-plugin-cursor-handoff 🧲

Hand off well-scoped implementation work from Claude Code to the
[Cursor CLI](https://cursor.com/cli) in headless mode, then review the diff and
iterate — without leaving Claude Code.

## 🧭 Contents

- [✨ What you get](#-what-you-get)
- [✅ Requirements](#-requirements)
- [📦 Install](#-install)
- [🚀 Using it](#-using-it)
  - [Your first handoff](#your-first-handoff)
  - [Scaling up: orchestration](#scaling-up-orchestration)
  - [Splitting the work explicitly](#splitting-the-work-explicitly)
  - [What NOT to hand off](#what-not-to-hand-off)
  - [Where things live](#where-things-live)
- [⚙️ Config](#️-config)
- [🧠 Repo context is inherited](#-repo-context-is-inherited)
- [🛡️ Safety properties](#️-safety-properties)
- [💡 Inspiration](#-inspiration)

## ✨ What you get

An orchestrator where the expensive model only spends tokens on task contracts
and patch review, while Cursor handles the code changes.

- `/cursor-handoff:handoff <task>` — forward a self-contained instruction through
  `cursor-agent -p`, review the diff, iterate.
- `/cursor-handoff:continue <chat-id> <feedback>` — resume the same Cursor session
  with pointed feedback (session context is preserved).
- `/cursor-handoff:orchestrate <big task>` — three-tier mode:
  1. The main model decomposes and reviews.
  2. One `handoff-manager` subagent per task writes the executor prompt, runs the
     worktree-isolated handoff, verifies, and returns a patch + compact report.
  3. Cursor does the code changes.

## ✅ Requirements

- Claude Code >= 2.x with plugin support
- Cursor CLI: `cursor-agent login` in a local terminal. Login is a browser flow; a headless
  handoff cannot complete it for you.
  - Alternative: `CURSOR_API_KEY` also works in non-interactive environments,
    although API-key usage may follow different Cursor API/SDK pricing than
    logged-in CLI usage.
- GNU `timeout` on `PATH` for watchdogs. On macOS, install coreutils so
  `gtimeout` is available.

## 📦 Install

```bash
claude plugin marketplace add rebelliard/claude-plugin-cursor-handoff
claude plugin install cursor-handoff@rebelliard
```

## 🚀 Using it

- Restart Claude Code after installing.
- Verify Cursor CLI auth once:
  - `cursor-agent status` should say `Logged in`.
  - If it does not, run `cursor-agent login` and complete the browser flow before
    starting a handoff.
- Use namespaced slash commands:
  - `/cursor-handoff:handoff`
  - `/cursor-handoff:continue`
  - `/cursor-handoff:orchestrate`

### Your first handoff

Pick something mechanical but worth offloading: a small migration, repetitive
test updates, or boilerplate across multiple files.

```text
/cursor-handoff:handoff migrate dashboard settings forms from legacy FieldRow/Input to shared FormField/TextInput components; preserve labels, validation, and component tests
```

What happens, in order — you can watch it in the transcript:

1. Claude forwards a compact **self-contained instruction** to Cursor: the
   user's request, essential file hints or verification, and "do not commit,
   stage, or push unless explicitly asked." The executor gets none of your
   conversation context, so the instruction must stand on its own.
2. It runs the handoff through the plugin's hardened wrapper (never
   `cursor-agent` directly), which prints a `CHAT_ID` — the resume handle —
   and a `LOG` path.
3. Claude then reviews the resulting `git diff` and **re-runs the verification
   commands itself** — the executor claiming success is not evidence.
4. You get a summary: what changed, whether checks pass, and the `CHAT_ID`.

The result didn't quite land? Iterate in the same Cursor session — context is
preserved, so feedback can be terse:

```text
/cursor-handoff:continue last also update Storybook stories and tests that still import FieldRow; they should use FormField/TextInput now
```

One feedback round is the budget; after that Claude takes the task over
itself. That's deliberate — looping a cheap executor on a task it keeps
missing costs more than escalating.

### Scaling up: orchestration

For multi-part work, don't feed tasks in one at a time:

```text
/cursor-handoff:orchestrate migrate dashboard route groups from inline loading spinners
to shared Skeleton states; split by route folder and keep Playwright smoke tests
passing
```

Orchestration keeps each execution lane isolated:

- Claude decomposes the work into file-disjoint tasks.
- Each task goes to a `handoff-manager` subagent.
- Each manager runs its executor pass in an **isolated git worktree**.
- Each manager verifies the result and returns a patch + ten-line report.
- Claude reviews each patch, applies and commits them sequentially, then re-runs
  verification on the whole.
- Your main checkout is never touched by an unattended run; you can keep working
  in it the entire time.

You can also skip the command and use natural language:

```text
send the settings form component migration to Cursor
run the dashboard loading-state migrations by route folder in parallel
```

The `cursor-handoff` skill triggers on intent and applies the same delegation
rules.

### Splitting the work explicitly

The orchestrate prompt is read by your main model, so be explicit:

- Say what Claude should keep.
- Say what Cursor should execute.
- The default split is good: judgment stays, execution goes.
- Stating the split per task beats hoping for it.

**Selective delegation — keep the judgment calls, route the typing:**

```text
/cursor-handoff:orchestrate add a compact density variant to the dashboard table UI.
Keep for yourself: the visual API, responsive behavior, and final review.
Send to Cursor: prop plumbing in Table, Toolbar, and row components; Storybook
examples; and interaction-test updates.
```

**Engineering loop — iterate handoffs until a check is clean:**

```text
/cursor-handoff:orchestrate drive `pnpm lint --filter web` and
`pnpm typecheck --filter web` to zero errors. You triage accessibility rule
exceptions and public component API changes yourself. Send Cursor file-disjoint
batches of import cleanup, unused props, hook dependency, and test type fixes.
```

Every tier is pinnable:

- The orchestrator is whatever your session runs.
- Managers use their agent definition.
- The executor can be pinned per task with the optional `MODEL:` contract field,
  or globally via `CURSOR_HANDOFF_MODEL`.

```text
For pure presentational prop rename batches, set MODEL: <fast executor model>.
Keep checkout, auth, and data-fetching routes on the default executor model.
```

### What NOT to hand off

- Keep these with Claude:
  - Ambiguous design work.
  - Taste-critical UI/API decisions.
  - Security-sensitive changes.
- Browser verification is delegateable only when the target repo already
  provides a headless browser skill or an explicit command such as Playwright.
- `cursor-agent` itself does not add browser tooling.

### Where things live

| Thing                    | Location                                                                                   |
| ------------------------ | ------------------------------------------------------------------------------------------ |
| Run logs                 | `~/.cache/cursor-handoff/logs/<timestamp>-<chat-id>.log` (14-day rotation)                 |
| Run metadata             | `~/.cache/cursor-handoff/runs/<chat-id>.env` plus `latest.env` for `continue last`         |
| Worktrees                | `~/.cursor/worktrees/<repo>/<name>` (cleanup must remove both the worktree and its branch) |
| Resume a session by hand | `scripts/cursor-run.sh continue <CHAT_ID> --workspace <WORKTREE> <prompt-file>`            |

## ⚙️ Config

| Env var                       | Default        | Meaning                                                                                                    |
| ----------------------------- | -------------- | ---------------------------------------------------------------------------------------------------------- |
| `CURSOR_HANDOFF_MODEL`        | `composer-2.5` | [Executor model](https://cursor.com/docs/models-and-pricing#model-pricing) (`cursor-agent models` to list) |
| `CURSOR_HANDOFF_TIMEOUT`      | `1800`         | Watchdog seconds for the executor run                                                                      |
| `CURSOR_HANDOFF_AUTH_TIMEOUT` | `30`           | Watchdog seconds for `cursor-agent status`                                                                 |
| `CURSOR_HANDOFF_CHAT_TIMEOUT` | `60`           | Watchdog seconds for `cursor-agent create-chat`                                                            |

## 🧠 Repo context is inherited

Headless runs use the same agent runtime as the Cursor IDE:

- The workspace's `AGENTS.md`, `.cursor/skills/`, `.cursor/rules`, and
  `.cursor/mcp.json` are loaded automatically.
- Skills + `AGENTS.md` loading have been verified empirically.
- Handoff instructions only need task-specific context, not repo conventions.

## 🛡️ Safety properties

- In-place `new` runs refuse a dirty working tree (override: `--dirty-ok`, or
  use `--worktree`).
- `continue` resumes in the recorded worktree when metadata is available;
  otherwise it requires `--workspace` or an explicit `--in-place` opt-in.
- `--force`/`--trust` are confined to the chosen workspace; worktree mode keeps
  unattended edits out of your checkout entirely.
- MCP access is not auto-approved by default. Use `--approve-mcps` only when the
  user explicitly asks for MCP-backed work, such as repo-provided browser tools.
- Handoff instructions tell Cursor not to commit, stage, or push unless the user
  explicitly asks.
- Logs and metadata are stored with restrictive permissions, but logs may still
  contain prompts, diffs, and command output. Do not put secrets in handoff
  prompts.

## 💡 Inspiration

This borrows the handoff shape popularized by [codex-plugin-cc](https://github.com/openai/codex-plugin-cc), adapted for Cursor's headless CLI and worktree flow.
