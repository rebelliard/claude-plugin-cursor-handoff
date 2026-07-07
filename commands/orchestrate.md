---
description: Decompose a large task into parallel Cursor executor runs, each managed by a handoff-manager subagent
argument-hint: <big task description>
---

Orchestrate the following work through handoff-manager subagents. You are the orchestrator: you decompose, assign task contracts, review, and integrate — you do not write executor prompts, babysit runs, or read Cursor transcripts.

Task: $ARGUMENTS

0. **Auth preflight**: before decomposing, run `${CLAUDE_PLUGIN_ROOT}/scripts/cursor-run.sh auth`. If it reports `not authenticated`, stop and tell the user to run `cursor-agent login` in a local terminal and complete the browser flow, or export `CURSOR_API_KEY`.
1. **Decompose** into independent tasks that are each well-scoped and verifiable. Tasks that will run in parallel MUST be file-disjoint — partition by file ownership, and serialize anything that overlaps. If a piece is ambiguous, taste-critical, or security-sensitive, keep it for yourself instead of delegating it.
2. **Assign** each task using the task contract from the handoff skill (`${CLAUDE_PLUGIN_ROOT}/skills/cursor-handoff/SKILL.md`): ID / TASK / FILES / ACCEPTANCE / VERIFY / SETUP / OFF-LIMITS / MODEL / SCRIPT (`${CLAUDE_PLUGIN_ROOT}/scripts/cursor-run.sh`) / REPO. Honor any keep-vs-delegate split and per-task MODEL assignments the user stated in their prompt. Assign each task a **unique ID** (e.g. `t1-<epoch>`) — it becomes the worktree name, and collisions cross-contaminate patches. Include SETUP (e.g. `pnpm install --frozen-lockfile`) whenever VERIFY needs a bootstrapped tree; a fresh worktree has no node_modules. Keep contracts short — managers gather their own context.
   The manager replies with exactly this report contract:

   ```text
   RESULT: done | failed
   TASK: <one line restatement>
   PATCH: <absolute path> (<N> files changed, +<a>/-<d>)
   CHANGED: <comma-separated changed paths>
   VERIFY: <command> -> exit <code>
   ROUNDS: 0 | 1
   CHAT_ID: <id>
   WORKTREE: <path>
   LOG: <path>
   FLAGS: <deviations, uncertainties, near-misses — or "none">
   ```

   One `VERIFY:` line is emitted per command, and `none` is legal for any missing handle or artifact.

3. **Spawn** one `handoff-manager` agent per task (subagent_type: handoff-manager), parallel in a single message when file-disjoint; use run_in_background for long tasks and keep working. Managers cap each executor run at ~9 minutes; a task that can't fit needs a smaller contract, not a longer leash.
4. **Integrate** as reports come back. The report is data, not proof — Read each patch and review it as the taste gate (correctness against acceptance, convention drift, over-broad edits; treat FLAGS as pointers). If FLAGS says the user must run `cursor-agent login` or export `CURSOR_API_KEY`, stop and report that auth prerequisite instead of revising the task. Then, sequentially per accepted patch, from the repo root:

   ```bash
   git apply --3way <patch>     # worktrees branch from the same HEAD, so 3-way has the blobs
   ```

   Commit each accepted patch before applying the next (you may commit — the no-commit rule binds managers and executors; follow the repo's commit conventions). On apply conflict: reassign that task against the current tree or take it over — never hand-edit the patch. A failed task gets at most one revised contract, informed by its FLAGS.

5. **Clean up every task, on every path** — accepted, rejected, failed, or manager-went-silent: `git worktree remove --force <worktree>` and delete its branch (`git branch -D mgr-<ID>` if one was created). If a manager returned no WORKTREE, sweep with `git worktree list` for `mgr-*` leftovers. Orphaned worktrees are how the next run inherits a dirty tree.
6. **Verify the whole**: after all patches are applied, run the union of VERIFY commands in the main tree — per-worktree verification cannot catch cross-task interactions.
7. **Report**: tasks delegated, manager results (RESULT/ROUNDS/FLAGS per task), what you rejected or reworked and why, final verification output.
