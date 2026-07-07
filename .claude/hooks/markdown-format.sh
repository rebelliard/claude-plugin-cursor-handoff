#!/bin/bash
# Format edited Markdown files. Errors are swallowed so edits are never blocked.

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.file_path // .tool_input.file_path // empty')

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

case "$FILE_PATH" in
  *.md|*.mdx)
    if command -v bunx >/dev/null 2>&1; then
      REPO_ROOT="$(git -C "$(dirname "$FILE_PATH")" rev-parse --show-toplevel 2>/dev/null || pwd)"
      PRETTIER_CONFIG="${REPO_ROOT}/.git-hooks/prettierrc.markdown.json"
      if [ -f "$PRETTIER_CONFIG" ]; then
        bunx prettier@3 --config "$PRETTIER_CONFIG" --write "$FILE_PATH" >/dev/null 2>&1
      fi
    fi
    ;;
esac

exit 0
