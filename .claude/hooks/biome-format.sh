#!/bin/bash
# Format edited files with Biome when Claude hooks pass a file path.

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [ -n "$FILE_PATH" ]; then
  npx @biomejs/biome check --write "$FILE_PATH" >/dev/null 2>&1
fi

exit 0
