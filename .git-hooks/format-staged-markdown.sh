#!/bin/bash
# Run prettier --write on staged Markdown files passed by Lefthook.

if [ $# -eq 0 ]; then
  exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PRETTIER_CONFIG="${REPO_ROOT}/.git-hooks/prettierrc.markdown.json"

if [ ! -f "$PRETTIER_CONFIG" ]; then
  echo "format-staged-markdown: missing ${PRETTIER_CONFIG}" >&2
  exit 1
fi

if command -v bunx >/dev/null 2>&1; then
  PRETTIER="bunx prettier@3"
else
  PRETTIER="npx --yes prettier@3"
fi

output=$($PRETTIER --config "$PRETTIER_CONFIG" --write "$@" 2>&1)
exit_code=$?

if [ $exit_code -ne 0 ]; then
  echo "$output"
  exit $exit_code
fi

echo "$output"
