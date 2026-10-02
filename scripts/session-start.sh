#!/bin/sh
# SessionStart: keeps Neovim's copy of the review threads current, so nvim
# loads them with no config of its own. Copies lua/ and plugin/ into the plugin
# data dir (stable across plugin updates, unlike the plugin root) and links
# that into nvim's package path. Also keeps a stable copy of bin/agent for
# /review-threads:install-agent to link.
#
# Prints nothing: a SessionStart hook's output becomes Claude's context.
command -v nvim >/dev/null 2>&1 || exit 0
root=${CLAUDE_PLUGIN_ROOT:-} data=${CLAUDE_PLUGIN_DATA:-}
[ -n "$root" ] && [ -n "$data" ] || exit 0

tmp="$data/nvim.$$"
mkdir -p "$tmp" && cp -R "$root/lua" "$root/plugin" "$tmp/" || { rm -rf "$tmp"; exit 0; }
rm -rf "$data/nvim" && mv "$tmp" "$data/nvim"
mkdir -p "$data/bin" && cp "$root/bin/agent" "$data/bin/agent" && chmod +x "$data/bin/agent"

pack="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/site/pack/review-threads/start"
mkdir -p "$pack" && ln -sfn "$data/nvim" "$pack/review-threads"
exit 0
