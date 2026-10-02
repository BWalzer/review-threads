# review-threads

Review Claude's work the way you review a pull request. You leave comments on lines in
Neovim; Claude, running beside it, answers in the thread and acts on it; you resolve the
thread when you're satisfied. You never edit the files yourself.

```
  3 We ship on Friday.
      ┌ t1    [reply] [resolve]  [collapse]
      │ ben: Which Friday? Put the date.
      │ claude: Changed it to Friday 9 October.
  4 Tests run nightly.
```

## Install

Requirements: [Claude Code](https://code.claude.com), [Neovim](https://neovim.io) 0.10 or
newer, git, and tmux (for the `agent` layout).

```sh
claude plugin marketplace add BWalzer/review-threads
claude plugin install review-threads@review-threads
```

Start Claude Code once afterwards. On every session start the plugin keeps Neovim's copy
current: it links itself into `~/.local/share/nvim/site/pack/review-threads/start/`, so
Neovim loads it with no config of yours. Then, once, inside Claude Code:

```
/review-threads:install-agent
```

which puts `agent` on your shell's PATH.

## Use

```sh
agent ~/code/some-repo
```

opens one tmux session: Neovim top left, Claude Code top right, a shell along the bottom.
Running it again reattaches.

In Neovim (`<leader>` is `\` unless you changed it):

| Keys | Does |
| --- | --- |
| `<leader>rc` | comment on the cursor line |
| `<leader>rr` | reply to the thread on this line |
| `<leader>rx` | resolve the thread on this line, or reopen it |
| `<leader>rz` | collapse or expand the thread on this line |
| `<leader>rl` | list open threads in the quickfix window (toggle) |
| `<leader>rd` | show the diff against HEAD over the whole file (toggle) |
| click | `[reply]` `[resolve]` `[collapse]` `[expand]` `[reopen]` on a thread's header |

Comment, and Claude picks it up within a couple of seconds: it reads the threads, makes
the change, and replies under your line. Files reload in Neovim as Claude edits them.

## How it works

- **Threads** live in `.git/review-threads.json`: per repository, never committed, never
  in a diff. Each is anchored to its line by content (the line plus two lines of context),
  so it follows the line as the file changes. When the line can't be found with confidence
  (rewritten, deleted, or ambiguous), the thread is marked outdated rather than moved to a
  wrong line.
- **Waking Claude**: the plugin runs `review watch` as a Claude Code monitor for the whole
  session. It notices a comment of yours that Claude hasn't seen and tells Claude, which
  runs `review show` and answers with `review reply`. Nothing types into Claude's terminal.
- **Permissions**: a hook approves `review show` and `review reply` (with its text in a
  quoted heredoc, or as plain words) so they never prompt. Anything else, those commands
  with more shell around them included, asks as usual.
- **Only you resolve threads.** Claude can reply but not resolve.

## Notes

- Neovim plugin managers that reset the package path (lazy.nvim does by default) skip the
  auto-installed copy. Point your manager at
  `~/.local/share/nvim/site/pack/review-threads/start/review-threads` instead, for example
  `{ dir = vim.fn.stdpath('data') .. '/site/pack/review-threads/start/review-threads' }`.
- `agent` sets `mouse` on for its session and `focus-events` and `escape-time 10` on the
  tmux server.
- Each Claude Code session keeps one small `review watch` process for its lifetime.

## Tests

```sh
nvim --clean --headless -l tests/review_test.lua
```

## License

MIT
