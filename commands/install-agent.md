---
description: Put the `agent` tmux launcher (nvim + Claude + shell) on your shell's PATH
---

Link the review-threads `agent` launcher into a directory on the user's shell PATH so they
can run `agent [dir]` from any terminal.

Link exactly this file, a stable copy the plugin keeps current across updates:

    ${CLAUDE_PLUGIN_DATA}/bin/agent

Never link anything under the plugin's install directory: that path changes on every update.

1. If that file does not exist yet, say so: it appears after the first session start with the
   plugin enabled. Ask the user to restart Claude Code and run this command again.
2. Run `command -v agent`. If it finds a command named `agent` that is not already a link to the
   file above, stop and ask the user before replacing or shadowing it.
3. Choose the target directory: `~/.local/bin` if it is on the user's PATH; otherwise, on macOS,
   `/opt/homebrew/bin` if it exists and is writable without sudo; otherwise create `~/.local/bin`
   and tell the user how to add it to PATH for their shell (`fish_add_path ~/.local/bin` for
   fish, `export PATH="$HOME/.local/bin:$PATH"` in `~/.zshrc` for zsh).
4. Create the link with `ln -sfn`, then confirm with `command -v agent`, and tell the user they
   can now run `agent` (or `agent <dir>`) in a fresh terminal. It needs tmux installed.
