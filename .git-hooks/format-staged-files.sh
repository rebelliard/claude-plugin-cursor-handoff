#!/bin/bash
# Run biome check --write on staged files passed by Lefthook.

if [ $# -eq 0 ]; then
  exit 0
fi

if [ -x "./node_modules/.bin/biome" ]; then
  BIOME="./node_modules/.bin/biome"
elif command -v bunx >/dev/null 2>&1; then
  BIOME="bunx @biomejs/biome"
else
  BIOME="npx --yes @biomejs/biome"
fi

output=$($BIOME check --write "$@" 2>&1)
exit_code=$?

if [ $exit_code -ne 0 ]; then
  if [[ "$output" == *"No files were processed"* ]]; then
    exit 0
  fi
  echo "$output"
  exit $exit_code
fi

echo "$output"
