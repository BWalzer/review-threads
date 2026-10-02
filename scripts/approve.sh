#!/bin/sh
# PreToolUse (Bash): approves Claude's own thread commands so they never ask:
# `review show`, and `review reply <id>` with its text in a quoted heredoc or
# as plain words. Anything else, those commands with more shell around them
# included, takes the usual permission path. approve.lua decides; this filter
# keeps every other Bash call from paying for a Neovim start.
input=$(cat)
case "$input" in
  *'"command":"review '*|*'"command": "review '*) ;;
  *) exit 0 ;;
esac
printf '%s' "$input" | exec nvim --clean -l "$(dirname "$0")/approve.lua"
