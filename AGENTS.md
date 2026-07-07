# Coding Instructions

Claude Code plugin (+ single-plugin marketplace) that hands off implementation
work to the Cursor CLI. Markdown contracts around one bash script.

## Contract sync rule (the one way to silently break this repo)

The task and report contracts appear in `agents/handoff-manager.md`
(canonical), `skills/cursor-handoff/SKILL.md`, and `commands/orchestrate.md`. A field
change that does not touch all three is a bug.

## Everything else

Before editing `scripts/cursor-run.sh`, the contract docs, or the manifests —
and before testing or releasing — use the `maintain-cursor-plugin` skill
(`.agents/skills/maintain-cursor-plugin/SKILL.md`). It holds the verified
`cursor-agent` ground truths, script invariants, test recipes, and the release
procedure. Never call `cursor-agent` directly; go through `scripts/cursor-run.sh`.
