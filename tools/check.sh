#!/usr/bin/env bash
# Syntax-checks every Luau source file with the standalone Luau CLI.
# Unknown-global diagnostics (CFrame, Color3, ...) are expected because the CLI
# has no Roblox type definitions, so only real syntax errors fail the build.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LUAU_BIN="${LUAU_BIN:-/tmp/luaubin/luau-analyze}"

if [[ ! -x "$LUAU_BIN" ]]; then
  echo "luau-analyze not found at $LUAU_BIN"
  echo "download: https://github.com/luau-lang/luau/releases/latest/download/luau-ubuntu.zip"
  exit 127
fi

fail=0
typewarn=0
while IFS= read -r file; do
  raw="$("$LUAU_BIN" "$file" 2>&1 || true)"
  # Real parse failures are the only thing that must break the build.
  syntax="$(printf '%s\n' "$raw" | grep -E 'SyntaxError|Expected identifier|Malformed|unexpected symbol' || true)"
  if [[ -n "$syntax" ]]; then
    echo "FAIL $file"
    echo "$syntax"
    fail=1
  fi
  # Type diagnostics are advisory: the CLI has no Roblox type definitions.
  types="$(printf '%s\n' "$raw" | grep -E 'TypeError' || true)"
  if [[ -n "$types" ]]; then
    typewarn=$((typewarn + 1))
    if [[ "${VERBOSE_TYPES:-0}" == "1" ]]; then
      echo "TYPES $file"
      echo "$types"
    fi
  fi
done < <(find "$ROOT/src" -name '*.luau' | sort)

if [[ "$fail" -eq 0 ]]; then
  echo "OK: all Luau files parsed cleanly (type advisories in $typewarn files; set VERBOSE_TYPES=1 to show)"
fi
exit "$fail"
