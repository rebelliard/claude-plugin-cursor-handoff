#!/usr/bin/env bash
# Headless Cursor handoff runner for Claude Code.
#
# Wraps `cursor-agent` print mode with the guardrails the raw CLI lacks:
#   - auth preflight and error detection by PARSING OUTPUT (cursor-agent
#     exits 0 even on "Authentication required" and other errors)
#   - dirty-tree guard for in-place runs (--force auto-runs shell commands,
#     so never mix an unattended run into uncommitted work by default)
#   - optional git-worktree isolation via cursor-agent -w
#   - a hard timeout watchdog so a stalled run can't block forever
#   - per-chat logs/metadata with rotation, and a stable CHAT_ID for resume
#
# Usage:
#   cursor-run.sh auth
#   cursor-run.sh new      [opts] <prompt-file>
#   cursor-run.sh new      [opts] --prompt <text>
#   cursor-run.sh continue <chat-id|last> [opts] <prompt-file>
#   cursor-run.sh continue <chat-id|last> [opts] --prompt <text>
#
# Options:
#   --model <id>        Model (default: $CURSOR_HANDOFF_MODEL or composer-2.5)
#   --prompt <text>     Inline prompt text (alternative to <prompt-file>)
#   --worktree          Run in an isolated git worktree (~/.cursor/worktrees/)
#   --worktree-name <n> Name for the worktree (default: handoff-<timestamp>)
#   --workspace <path>  Run in an explicit directory (e.g. continue in a worktree)
#   --in-place          Continue in the current checkout instead of a workspace
#   --mode <plan|ask>   Read-only modes (no edits, no shell)
#   --dirty-ok          Allow an in-place run despite uncommitted changes
#   --approve-mcps      Let the executor auto-approve MCP tool access (explicit opt-in)
#   --timeout <secs>    Watchdog (default: $CURSOR_HANDOFF_TIMEOUT or 1800)
#
# Output (machine-readable): `auth` prints STATUS=ok on success. For runs,
# CHAT_ID=, LOG=, WORKTREE= (if used) are printed BEFORE the run so they
# survive any failure; STATUS=ok is the last line on success. Exit: 0 on
# success, 1 on any detected failure. MCP servers are approved only when the
# caller passes --approve-mcps explicitly.
set -uo pipefail
umask 077

die() { echo "cursor-run: error: $*" >&2; exit 1; }

TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
[ -n "$TIMEOUT_BIN" ] || die "GNU timeout is required for the handoff watchdog. Install coreutils (gtimeout on macOS) and retry"
AUTH_TIMEOUT_SECS="${CURSOR_HANDOFF_AUTH_TIMEOUT:-30}"
CHAT_TIMEOUT_SECS="${CURSOR_HANDOFF_CHAT_TIMEOUT:-60}"

with_timeout() {
  local seconds="$1"
  shift

  "$TIMEOUT_BIN" --kill-after=5s "$seconds" "$@"
}

ensure_auth() {
  command -v cursor-agent >/dev/null 2>&1 \
    || die "cursor-agent not installed. Install: curl https://cursor.com/install -fsS | bash"

  # API-key based environments do not necessarily make `cursor-agent status`
  # print "Logged in", so trust an explicit token and let the actual run prove it.
  if [ -n "${CURSOR_API_KEY:-}${CURSOR_AUTH_TOKEN:-}" ]; then
    return
  fi

  # Auth preflight. Exit codes are useless here: parse the output.
  STATUS_OUTPUT="$(with_timeout "$AUTH_TIMEOUT_SECS" cursor-agent status 2>&1)"
  STATUS_RC=$?
  if [ "$STATUS_RC" = 124 ] || [ "$STATUS_RC" = 137 ]; then
    die "auth check timed out after ${AUTH_TIMEOUT_SECS}s. Run 'cursor-agent status' locally to diagnose"
  fi
  if ! printf '%s\n' "$STATUS_OUTPUT" | grep -q "Logged in"; then
    die "not authenticated. Run 'cursor-agent login' (browser flow) or export CURSOR_API_KEY"
  fi
}

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/cursor-handoff"
RUNS_DIR="$CACHE_DIR/runs"
mkdir -p "$CACHE_DIR/logs"
mkdir -p "$RUNS_DIR"
chmod 700 "$CACHE_DIR" "$CACHE_DIR/logs" "$RUNS_DIR" 2>/dev/null || true
find "$CACHE_DIR/logs" -type f -mtime +14 -delete 2>/dev/null
find "$RUNS_DIR" -type f -mtime +14 -delete 2>/dev/null

metadata_value() {
  local key="$1"
  local file="$2"
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$file"
}

write_run_metadata() {
  local run_worktree="${WORKTREE_PATH:-${METADATA_WORKTREE:-}}"
  local run_metadata="$RUNS_DIR/${CHAT_ID}.env"

  {
    printf 'CHAT_ID=%s\n' "$CHAT_ID"
    printf 'LOG=%s\n' "$LOG"
    printf 'WORKTREE=%s\n' "$run_worktree"
    printf 'WORKSPACE=%s\n' "$WORKSPACE"
    printf 'UPDATED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$run_metadata"
  cp "$run_metadata" "$CACHE_DIR/latest.env"
}

CMD="${1:-}"
shift || true
case "$CMD" in
  auth)
    [ "$#" -eq 0 ] || die "auth takes no arguments"
    ensure_auth
    echo "STATUS=ok"
    exit 0
    ;;
  new) CHAT_ID="" ;;
  continue)
    CHAT_ID="${1:-}"
    shift || true
    [ -n "$CHAT_ID" ] || die "continue requires a chat id"
    ;;
  *) die "first arg must be 'auth', 'new', or 'continue <chat-id>'" ;;
esac

MODEL="${CURSOR_HANDOFF_MODEL:-composer-2.5}"
TIMEOUT_SECS="${CURSOR_HANDOFF_TIMEOUT:-1800}"
MODE="" WORKTREE_NAME="" USE_WORKTREE=0 WORKSPACE="" DIRTY_OK=0 IN_PLACE=0 APPROVE_MCPS=0 PROMPT_FILE="" INLINE_PROMPT="" INLINE_PROMPT_SET=0 METADATA_WORKTREE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL="${2:?}"; shift 2 ;;
    --worktree) USE_WORKTREE=1; shift ;;
    --worktree-name) USE_WORKTREE=1; WORKTREE_NAME="${2:?}"; shift 2 ;;
    --workspace) WORKSPACE="${2:?}"; shift 2 ;;
    --in-place) IN_PLACE=1; shift ;;
    --mode) MODE="${2:?}"; shift 2 ;;
    --dirty-ok) DIRTY_OK=1; shift ;;
    --approve-mcps) APPROVE_MCPS=1; shift ;;
    --timeout) TIMEOUT_SECS="${2:?}"; shift 2 ;;
    --prompt) INLINE_PROMPT="${2:?}"; INLINE_PROMPT_SET=1; shift 2 ;;
    --prompt=*) INLINE_PROMPT="${1#--prompt=}"; INLINE_PROMPT_SET=1; shift ;;
    -*) die "unknown option: $1" ;;
    *)
      [ -z "$PROMPT_FILE" ] || die "multiple prompt files provided"
      PROMPT_FILE="$1"
      shift
      ;;
  esac
done

if [ "$IN_PLACE" -eq 1 ] && [ "$CMD" != "continue" ]; then
  die "--in-place is only valid with continue"
fi
if [ "$IN_PLACE" -eq 1 ] && [ -n "$WORKSPACE" ]; then
  die "provide either --workspace or --in-place, not both"
fi

if [ "$CMD" = "continue" ]; then
  if [ "$CHAT_ID" = "last" ]; then
    [ -f "$CACHE_DIR/latest.env" ] || die "no latest handoff metadata found; pass an explicit chat id and --workspace or --in-place"
    CHAT_ID="$(metadata_value CHAT_ID "$CACHE_DIR/latest.env")"
    METADATA_WORKTREE="$(metadata_value WORKTREE "$CACHE_DIR/latest.env")"
    [ -n "$CHAT_ID" ] || die "latest handoff metadata is missing CHAT_ID"
  elif [ -f "$RUNS_DIR/${CHAT_ID}.env" ]; then
    METADATA_WORKTREE="$(metadata_value WORKTREE "$RUNS_DIR/${CHAT_ID}.env")"
  fi

  if [ -z "$WORKSPACE" ] && [ -n "$METADATA_WORKTREE" ]; then
    [ -d "$METADATA_WORKTREE" ] || die "recorded worktree no longer exists: $METADATA_WORKTREE"
    WORKSPACE="$METADATA_WORKTREE"
  fi
  if [ -z "$WORKSPACE" ] && [ "$IN_PLACE" -eq 0 ]; then
    die "continue requires --workspace <path> or --in-place; use 'last' only when handoff metadata is available"
  fi
fi

if [ "$INLINE_PROMPT_SET" -eq 1 ] && [ -n "$PROMPT_FILE" ]; then
  die "provide either --prompt or a prompt file, not both"
elif [ "$INLINE_PROMPT_SET" -eq 1 ]; then
  PROMPT="$INLINE_PROMPT"
elif [ -n "$PROMPT_FILE" ]; then
  PROMPT="$(cat "$PROMPT_FILE")" || die "could not read prompt file: $PROMPT_FILE"
else
  die "missing prompt; provide --prompt or a prompt file"
fi

[ -n "$PROMPT" ] || die "prompt missing or empty"
[ "$(printf '%s' "$PROMPT" | wc -c)" -lt 200000 ] || die "prompt >200KB; trim it (ARG_MAX risk)"

echo "STEP=auth"
ensure_auth

# Workspace safety: NEW in-place unattended runs require a clean tree.
# CONTINUE must resolve a workspace from metadata or use explicit --in-place.
if [ "$CMD" = "new" ] && [ "$USE_WORKTREE" -eq 0 ] && [ -z "$WORKSPACE" ] && [ -z "$MODE" ] && [ "$DIRTY_OK" -eq 0 ]; then
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1 && [ -n "$(git status --porcelain)" ]; then
    die "working tree has uncommitted changes; use --worktree, or --dirty-ok to override"
  fi
fi

if [ "$CMD" = "new" ]; then
  echo "STEP=create-chat"
  CREATE_CHAT_OUTPUT="$(with_timeout "$CHAT_TIMEOUT_SECS" cursor-agent create-chat 2>&1)"
  CREATE_CHAT_RC=$?
  if [ "$CREATE_CHAT_RC" = 124 ] || [ "$CREATE_CHAT_RC" = 137 ]; then
    die "create-chat timed out after ${CHAT_TIMEOUT_SECS}s. Run 'cursor-agent status' locally and retry"
  fi
  [ "$CREATE_CHAT_RC" -eq 0 ] || die "create-chat failed: $CREATE_CHAT_OUTPUT"
  # `create-chat` may print informational lines before the id; the stable handle
  # is the final non-empty line with whitespace stripped.
  CHAT_ID="$(printf '%s\n' "$CREATE_CHAT_OUTPUT" | awk 'NF { last=$0 } END { gsub(/[[:space:]]/, "", last); print last }')"
  case "$CHAT_ID" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-*) ;;
    *) die "create-chat did not return a chat id (got: '$CHAT_ID'). Is the CLI authenticated?" ;;
  esac
fi

ARGS=(-p "$PROMPT" --resume "$CHAT_ID" --output-format text --force --trust --model "$MODEL")
[ -n "$MODE" ] && ARGS+=(--mode "$MODE")
[ "$APPROVE_MCPS" -eq 1 ] && ARGS+=(--approve-mcps)
WORKTREE_PATH=""
if [ "$USE_WORKTREE" -eq 1 ]; then
  [ -n "$WORKTREE_NAME" ] || WORKTREE_NAME="handoff-$(date +%Y%m%d-%H%M%S)"
  ARGS+=(-w "$WORKTREE_NAME")
  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    # Cursor creates -w worktrees in this fixed cache location; predicting it
    # lets callers clean up or inspect a failed run without parsing transcripts.
    WORKTREE_PATH="$HOME/.cursor/worktrees/$(basename "$(git rev-parse --show-toplevel)")/$WORKTREE_NAME"
  fi
elif [ -n "$WORKSPACE" ]; then
  [ -d "$WORKSPACE" ] || die "workspace does not exist: $WORKSPACE"
  ARGS+=(--workspace "$WORKSPACE")
fi

if [ -n "$WORKTREE_PATH" ] && [ -e "$WORKTREE_PATH" ]; then
  die "worktree already exists: $WORKTREE_PATH — pick a unique --worktree-name"
fi

LOG="$CACHE_DIR/logs/$(date +%Y%m%d-%H%M%S)-${CHAT_ID}.log"
write_run_metadata

# Print resume/cleanup handles up front: a failed or killed run must still be
# resumable and its worktree removable.
echo "CHAT_ID=$CHAT_ID"
echo "LOG=$LOG"
[ -n "$WORKTREE_PATH" ] && echo "WORKTREE=$WORKTREE_PATH"
echo "STEP=run"

"$TIMEOUT_BIN" --kill-after=30s "$TIMEOUT_SECS" \
  cursor-agent "${ARGS[@]}" 2>&1 | tee "$LOG"
# The pipeline exit code would normally be tee's status; PIPESTATUS[0] keeps
# cursor-agent/timeout as the source of truth.
RC="${PIPESTATUS[0]}"

if [ "$RC" = 124 ] || [ "$RC" = 137 ]; then
  die "run timed out after ${TIMEOUT_SECS}s (log: $LOG)"
fi

# cursor-agent exits 0 on many failures; detect them from the transcript.
ERROR_PATTERN='error:|authentication required|not logged in'
if grep -qiE "$ERROR_PATTERN" "$LOG"; then
  die "cursor-agent reported an error (log: $LOG): $(grep -im1 -E "$ERROR_PATTERN" "$LOG")"
fi
[ "$RC" -eq 0 ] || die "cursor-agent exited with code $RC (log: $LOG)"

echo ""
echo "STATUS=ok"
exit 0
