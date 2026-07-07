---
name: maintain-cursor-plugin
description: Maintain, test, and release the cursor handoff plugin in this repository. Use when editing cursor-run.sh, the handoff-manager agent, the handoff skill, commands, or plugin manifests; when testing a handoff end to end; when releasing a new plugin version; or when debugging cursor-agent behavior (auth, worktrees, exit codes).
---

# Maintain the cursor plugin

## Ground truths about `cursor-agent` (verified; do not re-litigate)

- **It exits 0 on failure** — auth errors, bad models, everything. Never branch
  on its exit code; parse output (`Error:`, `Not logged in`, `Authentication
required`). This is the reason `scripts/cursor-run.sh` exists; never call
  `cursor-agent` raw.
- Auth is a browser flow (`cursor-agent login`); headless sessions cannot
  complete it. `cursor-agent status` output is the auth check;
  `cursor-agent models` needs auth even when `status` says logged in.
- The wrapper requires GNU `timeout` (`timeout` or Homebrew `gtimeout`) so the
  watchdog is real; do not silently fall back to unbounded runs.
- Keychain access: sandboxed shells can't read the token — disable the sandbox
  for test invocations.
- `-w <name>` creates worktrees at `~/.cursor/worktrees/<repo-basename>/<name>`,
  never cleans them up, and leaves a branch behind that `git worktree remove`
  does not delete.
- `create-chat` + `--resume <id> -p` preserves session context headlessly.
- Headless runs load the workspace's `AGENTS.md`, `.cursor/skills/`, and
  `.cursor/rules` automatically — executor prompts must not restate repo
  conventions.

## `cursor-run.sh` invariants (breaking any of these breaks the manager agent)

- `STEP=auth`, `STEP=create-chat`, `STEP=run` expose where a run is spending
  time; `CHAT_ID=`, `LOG=`, `WORKTREE=` print **before** the executor run so
  failures stay resumable and cleanable; `STATUS=ok` is the last line on
  success; exit 0 is the success signal.
- Refuses a pre-existing worktree path (collisions cross-contaminate patches).
- Dirty-tree guard applies to `new` in-place runs only. `continue` must be
  explicit about its target: a recorded or provided `--workspace`, or
  `--in-place` when the caller intentionally resumes in the current checkout.
- `--approve-mcps` is explicit opt-in only. Do not enable it by default; use it
  only when the user asks for MCP-backed work, such as repo-provided browser
  tools.
- `set -uo pipefail` without `-e` is deliberate; guards check `$?`/`PIPESTATUS`
  after non-fatal failures.

## Writing contract docs

The agent/skill/command docs are executed by a mid-tier model following them
literally:

- No ambiguity between hard rules and protocol steps — a hard rule that a step
  violates gets resolved unpredictably.
- Every failure path must end in an emittable report; `none` is the legal
  placeholder, invented values never are.
- Principles first, model names as replaceable examples — model ids rot.

## Testing changes

CI runs `pnpm check:ci` and intentionally skips `claude plugin validate .`
because GitHub Actions does not have Claude Code installed. Test empirically
before committing behavior changes:

1. `bash -n scripts/cursor-run.sh` and `claude plugin validate .`
2. E2E in a scratch git repo: seed a trivial bug, commit, run a handoff, check
   the diff/patch round trip. Requires a logged-in `cursor-agent`; runs cost
   real Cursor executor usage — keep prompts tiny.
3. Protocol changes to `agents/handoff-manager.md`: simulate by spawning a
   manager subagent instructed to follow the file literally against the scratch
   repo, and check the report parses field-for-field.
4. Nontrivial protocol/architecture changes: run an adversarial review from a
   fresh critic context before shipping — it has caught blockers in every
   revision so far.
5. Clean up every test worktree: `git worktree remove --force` + `git branch -D`,
   both in the scratch repo and under `~/.cursor/worktrees/`.

## Releasing

Installed copies are version-pinned caches; edits do not flow until:

```bash
# bump the version in BOTH manifests (they must match)
sed -i '' 's/"version": "<old>"/"version": "<new>"/' .claude-plugin/plugin.json .claude-plugin/marketplace.json
claude plugin validate . && git commit ...
claude plugin marketplace update rebelliard
claude plugin update cursor-handoff@rebelliard   # then restart Claude Code
```

Docs-only changes need no bump. `plugin.json` must NOT declare an `"agents"`
field — agent discovery is by convention (`./agents`), and the explicit field
fails validation.
