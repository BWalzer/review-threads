-- Tests for files/lua/review. Run from the repo root:
--   nvim --clean --headless -l modules/nvim/tests/review_test.lua
-- Builds throwaway git repos under a temp dir.
local here = vim.fs.dirname(vim.fs.abspath(arg[0]))
local root = vim.fs.normalize(here .. '/..')
local lib = root .. '/lua'
package.path = lib .. '/?.lua;' .. lib .. '/?/init.lua;' .. package.path

local anchor = require('review.anchor')
local store = require('review.store')

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    print('FAIL ' .. name .. '\n  ' .. tostring(err))
  end
end
local function eq(got, want, what)
  if not vim.deep_equal(got, want) then
    error(('%s: want %s, got %s'):format(what or 'value', vim.inspect(want), vim.inspect(got)), 2)
  end
end
local function has(text, part)
  if not text:find(part, 1, true) then
    error(('expected %q in:\n%s'):format(part, text), 2)
  end
end

-- ---- anchors -------------------------------------------------------------

local FILE = {
  'import { load } from "./load"',
  '',
  'export function total(items) {',
  '  let sum = 0',
  '  for (const item of items) {',
  '    sum += item.price',
  '  }',
  '  return sum',
  '}',
}
local function at(lines, n) return assert(anchor.anchor_at(lines, n)) end
local function copy(t) return vim.list_extend({}, t) end

test('a line where it was is found', function()
  eq(anchor.locate(at(FILE, 6), FILE), { line = 6 })
end)

test('a line moved down 10 lines is found again', function()
  local moved = {}
  for k = 1, 10 do moved[k] = '// header ' .. k end
  eq(anchor.locate(at(FILE, 6), vim.list_extend(moved, FILE)), { line = 16 })
end)

test('a line moved up is found again', function()
  eq(anchor.locate(at(FILE, 6), vim.list_slice(FILE, 3)), { line = 4 })
end)

test('a rewritten line is outdated', function()
  local edited = copy(FILE)
  edited[6] = '    sum += item.cost'
  eq(anchor.locate(at(FILE, 6), edited), { reason = 'missing' })
end)

test('a deleted line is outdated', function()
  local edited = copy(FILE)
  table.remove(edited, 6)
  eq(anchor.locate(at(FILE, 6), edited).line, nil)
end)

test('trailing whitespace and CRLF do not move a thread', function()
  local crlf = anchor.lines_of(table.concat(vim.tbl_map(function(l) return l .. '  ' end, FILE), '\r\n'))
  eq(anchor.locate(at(FILE, 6), crlf), { line = 6 })
end)

test('an edited neighbour on one side keeps a distinctive line found', function()
  local edited = copy(FILE)
  edited[5] = '  for (const item of items.filter(Boolean)) {'
  edited[4] = '  let sum = 0 // running'
  eq(anchor.locate(at(FILE, 6), edited), { line = 6 })
end)

test('both sides of context rewritten → outdated, even for a unique line', function()
  local edited = copy(FILE)
  edited[4], edited[5], edited[7], edited[8] = '  let acc = 0', '  for (const it of items) {', '  } // done', '  return acc'
  eq(anchor.locate(at(FILE, 6), edited), { reason = 'weak' })
end)

local TWICE = { 'function a() {', '  const x = 1', '  return x', '}', 'function b() {', '  const x = 2', '  return x', '}' }

test('two identical lines: context tells them apart', function()
  eq(anchor.locate(at(TWICE, 3), TWICE), { line = 3 })
  eq(anchor.locate(at(TWICE, 7), TWICE), { line = 7 })
end)

test('two identical lines: still told apart after both move', function()
  local moved = vim.list_extend({ '// a', '// b', '' }, TWICE)
  eq(anchor.locate(at(TWICE, 3), moved), { line = 6 })
  eq(anchor.locate(at(TWICE, 7), moved), { line = 10 })
end)

test('two identical lines: a copy whose context moved apart is outdated', function()
  local swapped = vim.list_extend(vim.list_extend(vim.list_slice(TWICE, 5), { '' }), vim.list_slice(TWICE, 1, 4))
  eq(anchor.locate(at(TWICE, 3), swapped), { reason = 'ambiguous' })
end)

test('two identical lines: identical context is ambiguous, never a guess', function()
  local same = { 'x', '{', '  return x', '}', 'x', '{', '  return x', '}', 'x' }
  eq(anchor.locate(at(same, 3), same), { reason = 'ambiguous' })
end)

test("two identical lines: the commented copy's context changed → outdated", function()
  local edited = copy(TWICE)
  edited[2] = '  const x = 10'
  eq(anchor.locate(at(TWICE, 3), edited).line, nil)
end)

test('two identical lines: the commented copy deleted → outdated, not the other', function()
  local edited = copy(TWICE)
  table.remove(edited, 3)
  eq(anchor.locate(at(TWICE, 3), edited).line, nil)
end)

test('a trivial line is placed only by its whole context', function()
  eq(anchor.locate(at(FILE, 7), FILE), { line = 7 })
  local edited = copy(FILE)
  edited[6] = '    sum += item.cost'
  eq(anchor.locate(at(FILE, 7), edited).line, nil)
end)

test('a blank line between blank lines is never placed', function()
  local blanks = { '', '', '', '', '' }
  eq(anchor.locate(at(blanks, 3), blanks).line, nil)
end)

test('a one-line file places its distinctive line', function()
  eq(anchor.locate(at({ '# Title' }, 1), { '# Title' }), { line = 1 })
end)

test('out of range has no anchor', function()
  eq(anchor.anchor_at(FILE, 0), nil)
  eq(anchor.anchor_at(FILE, 99), nil)
end)

test('lines_of drops the empty line after a final newline only', function()
  eq(anchor.lines_of('a\nb\n'), { 'a', 'b' })
  eq(anchor.lines_of('a\n\n'), { 'a', '' })
  eq(anchor.lines_of(''), { '' })
end)

-- ---- a throwaway repo ----------------------------------------------------

local NOTES = '# Plan\n\nWe ship on Friday.\nTests run nightly.\n\n## Risks\nNone known.\n'
local tmp = vim.fn.tempname()

local function sh(cmd, dir)
  local r = vim.system({ 'sh', '-c', cmd }, { cwd = dir, text = true }):wait()
  assert(r.code == 0, cmd .. ': ' .. (r.stderr or ''))
  return r.stdout
end

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local f = assert(io.open(path, 'w'))
  f:write(text)
  f:close()
end

local n = 0
local function fresh_repo()
  n = n + 1
  local dir = ('%s/repo%d'):format(tmp, n)
  vim.fn.mkdir(dir, 'p')
  write(dir .. '/notes.md', NOTES)
  write(dir .. '/dup.ts', 'x\n{\n  return x\n}\nx\n{\n  return x\n}\nx\n')
  sh('git init -q && git add . && git -c user.name=t -c user.email=t@t commit -qm init', dir)
  return dir, assert(store.repo(dir))
end

-- ---- store and CLI -------------------------------------------------------

local cli = vim.fs.normalize(lib .. '/review/cli.lua')
local function review(dir, ...)
  local r = vim.system(vim.list_extend({ vim.v.progpath, '--clean', '-l', cli }, { ... }), { cwd = dir, text = true }):wait()
  return r.code, vim.trim(r.stdout .. r.stderr)
end

-- `review watch` running as Claude Code's monitor runs it. `lines()` is what it
-- has printed; `after(n)` waits until it has printed more than n lines.
local watchers = {}
local function watching(dir)
  local out = {}
  local proc = vim.system({ vim.v.progpath, '--clean', '-l', cli, 'watch' }, {
    cwd = dir,
    stdout = function(_, data)
      for line in (data or ''):gmatch('[^\n]+') do table.insert(out, line) end
    end,
  })
  table.insert(watchers, proc)
  local w = {}
  function w.lines() return out end
  function w.after(n, ms)
    vim.wait(ms or 5000, function() return #out > n end, 50)
    return out[n + 1]
  end
  return w
end

test('threads live in the git dir, keyed per repository', function()
  local dir, repo = fresh_repo()
  eq(repo.file, vim.uv.fs_realpath(dir) .. '/.git/review-threads.json')
  eq(store.repo(dir .. '/..') == nil, true, 'outside a repo')
end)

test('a thread is shown with its current lines and follows them', function()
  local dir, repo = fresh_repo()
  local t = assert(store.add(repo, 'notes.md', store.lines(repo, 'notes.md'), 3, 'Which Friday?'))
  eq(t.id, 't1')
  write(dir .. '/notes.md', 'Draft.\n' .. NOTES)
  local _, out = review(dir, 'show')
  has(out, '[t1] notes.md:4')
  has(out, '>    4 | We ship on Friday.')
  has(out, 'ben: Which Friday?')
  has(out, 'review reply <id>')
end)

test('a rewritten line shows the thread outdated', function()
  local dir, repo = fresh_repo()
  store.add(repo, 'notes.md', store.lines(repo, 'notes.md'), 3, 'Which Friday?')
  write(dir .. '/notes.md', (NOTES:gsub('Friday', 'the 9th')))
  local _, out = review(dir, 'show')
  has(out, '[t1] notes.md (outdated: the commented line changed or is gone; was line 3)')
  has(out, 'was: We ship on Friday.')
end)

test('a line that cannot be anchored is refused', function()
  local _, repo = fresh_repo()
  local t, err = store.add(repo, 'dup.ts', store.lines(repo, 'dup.ts'), 3, 'which one?')
  eq(t, nil)
  has(err, "can't be anchored")
  eq(#store.load(repo).threads, 0)
end)

test('review reply appends a claude comment; an unknown id fails', function()
  local dir, repo = fresh_repo()
  store.add(repo, 'notes.md', store.lines(repo, 'notes.md'), 3, 'Which Friday?')
  local code, out = review(dir, 'reply', 't1', 'Changed', 'it to the 9th.')
  eq(code, 0)
  has(out, 'Replied in t1.')
  eq(store.load(repo).threads[1].comments[2], { author = 'claude', text = 'Changed it to the 9th.', at = store.load(repo).threads[1].comments[2].at })
  code, out = review(dir, 'reply', 't7', 'Done.')
  eq(code, 1)
  has(out, 'no thread t7; threads here: t1')
end)

test('a resolved thread is kept but left out of review show', function()
  local dir, repo = fresh_repo()
  local lines = store.lines(repo, 'notes.md')
  store.add(repo, 'notes.md', lines, 3, 'Which Friday?')
  store.add(repo, 'notes.md', lines, 7, 'Name one.')
  store.set_resolved(repo, 't1', true)
  local _, out = review(dir, 'show')
  eq(out:find('[t1]', 1, true), nil, 't1 hidden')
  has(out, '[t2]')
  eq(#store.load(repo).threads, 2)
  store.set_resolved(repo, 't2', true)
  eq(select(2, review(dir, 'show')), 'No open review threads.')
end)

-- ---- review watch: Claude listening --------------------------------------

test('review watch announces a comment of Ben\'s, naming the thread', function()
  local dir, repo = fresh_repo()
  local w = watching(dir)
  vim.wait(3000, function() return store.is_listening(repo) end, 50)
  eq(store.is_listening(repo), true, 'listening while it runs')
  store.add(repo, 'notes.md', store.lines(repo, 'notes.md'), 3, 'Which Friday?')
  has(w.after(0) or '', 'Ben left new review comments on t1. Run `review show`')
end)

test("Claude's own reply announces nothing; Ben's next comment does", function()
  local dir, repo = fresh_repo()
  local w = watching(dir)
  store.add(repo, 'notes.md', store.lines(repo, 'notes.md'), 3, 'Which Friday?')
  has(w.after(0) or '', 'on t1')
  review(dir, 'show')
  review(dir, 'reply', 't1', 'The 9th.')
  eq(w.after(1, 3000), nil, "Claude's reply wakes nothing")
  store.comment(repo, 't1', 'ben', 'Which timezone?')
  has(w.after(1) or '', 'on t1')
end)

test('a comment left before Claude started is announced at once', function()
  local dir, repo = fresh_repo()
  store.add(repo, 'notes.md', store.lines(repo, 'notes.md'), 3, 'Which Friday?')
  has(watching(dir).after(0) or '', 'on t1')
end)

test('seen comments and resolving announce nothing', function()
  local dir, repo = fresh_repo()
  store.add(repo, 'notes.md', store.lines(repo, 'notes.md'), 3, 'Which Friday?')
  review(dir, 'show')
  local w = watching(dir)
  store.set_resolved(repo, 't1', true)
  store.set_resolved(repo, 't1', false)
  eq(w.after(0, 3000), nil)
end)

test('outside a repository review watch stays quiet and keeps running', function()
  local dir = tmp .. '/not-a-repo'
  vim.fn.mkdir(dir, 'p')
  local w = watching(dir)
  eq(w.after(0, 1500), nil)
  eq(watchers[#watchers]:is_closing(), false, 'still running')
end)

test('review reply takes its text from a quoted heredoc on stdin', function()
  local dir, repo = fresh_repo()
  store.add(repo, 'notes.md', store.lines(repo, 'notes.md'), 3, 'Which Friday?')
  local r = vim.system({ 'sh', '-c', root .. "/bin/review reply t1 <<'EOF'\nRenamed `friday` to $DATE.\nSecond line.\nEOF" }, { cwd = dir, text = true }):wait()
  eq(r.code, 0, r.stderr)
  eq(store.load(repo).threads[1].comments[2].text, 'Renamed `friday` to $DATE.\nSecond line.')
end)

-- ---- the approval hook ----------------------------------------------------

local function approves(command)
  local input = vim.json.encode({ hook_event_name = 'PreToolUse', tool_name = 'Bash', tool_input = { command = command } })
  local r = vim.system({ 'sh', root .. '/scripts/approve.sh' }, { stdin = input, text = true }):wait()
  return r.stdout:find('"permissionDecision":"allow"', 1, true) ~= nil
end

test('the hook approves review show and review reply, nothing more', function()
  eq(approves('review show'), true)
  eq(approves("review reply t3 <<'EOF'\nRenamed `x` to $(y); see below.\nEOF"), true)
  eq(approves('review reply t3 Done, renamed it.'), true)

  eq(approves('review show; rm -rf ~'), false, 'chained')
  eq(approves('review show && curl x'), false, 'chained')
  eq(approves("review reply t3 <<'EOF'\nok\nEOF\nrm -rf ~"), false, 'runs past the heredoc')
  eq(approves("review reply t3 <<'EOF'\nok\nEOF\nmore\nEOF"), false, 'tag inside the body')
  eq(approves("review reply t3 <<'EOF' && rm x\nok\nEOF"), false, 'shell after the opener')
  eq(approves('review reply t3 <<EOF\n$(rm x)\nEOF'), false, 'unquoted heredoc expands')
  eq(approves('review reply t3 "$(rm x)"'), false, 'double quotes expand')
  eq(approves('review watch'), false)
  eq(approves('ls'), false)
end)

-- ---- nvim ----------------------------------------------------------------

local review_ui = require('review')
review_ui.setup()

local said = {}
vim.notify = function(msg) table.insert(said, msg) end

local function answer(text)
  vim.ui.input = function(_, cb) cb(text) end
end

local function virt(buf)
  local marks = vim.api.nvim_buf_get_extmarks(buf or 0, vim.api.nvim_create_namespace('review'), 0, -1, { details = true })
  return marks, vim.inspect(vim.tbl_map(function(m) return m[4].virt_lines end, marks))
end

test('<leader>rc on a line starts a thread and draws it under the line', function()
  local dir, repo = fresh_repo()
  vim.cmd.edit(dir .. '/notes.md')
  vim.api.nvim_win_set_cursor(0, { 7, 0 })
  answer('Name two real risks.')
  review_ui.comment()

  eq(store.load(repo).threads[1].anchor.text, 'None known.')
  local marks, text = virt()
  eq(#marks, 1)
  eq(marks[1][2], 6, 'drawn under line 7')
  has(text, 'ben: Name two real risks.')
  has(said[#said], 't1 saved, but no Claude session is listening')
end)

test('with Claude listening, a comment says so and wakes it', function()
  local dir = fresh_repo()
  local w = watching(dir)
  vim.wait(3000, function() return store.is_listening(assert(store.repo(dir))) end, 50)
  vim.cmd.edit(dir .. '/notes.md')
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  answer('Which Friday?')
  review_ui.comment()
  has(said[#said], 't1 saved; Claude will pick it up')
  has(w.after(0) or '', 'on t1')
end)

test("Claude's reply appears under the line when the file changes", function()
  local dir, repo = fresh_repo()
  vim.cmd.edit(dir .. '/notes.md')
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  answer('Which Friday?')
  review_ui.comment()
  review(dir, 'reply', 't1', 'The 9th.')
  vim.wait(2000, function() return select(2, virt()):find('claude: The 9th.', 1, true) ~= nil end, 50)
  has(select(2, virt()), 'claude: The 9th.')
  eq(store.load(repo).threads[1].comments[2].author, 'claude')
end)

test('<leader>rr replies, <leader>rx resolves to one line and reopens', function()
  local dir, repo = fresh_repo()
  vim.cmd.edit(dir .. '/notes.md')
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  answer('Which Friday?')
  review_ui.comment()
  answer('Also: which timezone?')
  review_ui.reply()
  has(said[#said], 'reply in t1 saved')
  eq(#store.load(repo).threads[1].comments, 2)
  review_ui.resolve()
  eq(store.load(repo).threads[1].resolved, true)
  local marks, text = virt()
  eq(#marks[1][4].virt_lines, 1, 'one line')
  has(text, 'resolved · 2 comments')
  has(text, '[reopen]')
  review_ui.resolve()
  eq(store.load(repo).threads[1].resolved, false)
end)

test('an unsaved buffer is not commented on', function()
  local dir, repo = fresh_repo()
  vim.cmd.edit(dir .. '/notes.md')
  vim.api.nvim_buf_set_lines(0, 0, 0, false, { 'unsaved' })
  answer('x')
  review_ui.comment()
  eq(#store.load(repo).threads, 0)
  vim.cmd('silent! edit!')
end)


-- ---- wrapping, the diff, the list ----------------------------------------

test('wrap breaks at spaces within the width, and splits a long word', function()
  eq(review_ui.wrap('one two three four', 9), { 'one two', 'three', 'four' })
  eq(review_ui.wrap('abcdefghijkl', 5), { 'abcde', 'fghij', 'kl' })
  eq(review_ui.wrap('a\n\nb', 10), { 'a', '', 'b' })
end)

test('a long comment wraps to the window and keeps its indent', function()
  local dir = fresh_repo()
  vim.cmd('silent! only')
  vim.cmd.edit(dir .. '/notes.md')
  vim.cmd('vertical resize 40')
  vim.cmd('vsplit')
  vim.cmd('vertical resize 40')
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  answer(string.rep('word ', 30))
  review_ui.comment()
  local width = review_ui.text_width(0)
  local _, text = virt()
  local marks = virt()
  local rows = marks[1][4].virt_lines
  eq(#rows > 4, true, 'wrapped into several rows')
  for _, row in ipairs(rows) do
    eq(vim.fn.strdisplaywidth(row[1][1]) <= width, true, 'row fits: ' .. row[1][1])
  end
  has(text, '│ ben: word')
  has(rows[3][1][1], '│      word')
  vim.cmd('silent! only')
end)

test('hunks parse additions, changes and deletions', function()
  local h = require('review.diff').hunks(table.concat({
    'diff --git a/x b/x', '--- a/x', '+++ b/x',
    '@@ -3 +3 @@', '-old three', '+new three',
    '@@ -7,2 +6,0 @@', '-gone a', '-gone b',
    '@@ -0,0 +9,2 @@', '+new a', '+new b',
  }, '\n'))
  eq(h[1], { old_start = 3, old = 1, new_start = 3, new = 1, removed = { 'old three' } })
  eq(h[2], { old_start = 7, old = 2, new_start = 6, new = 0, removed = { 'gone a', 'gone b' } })
  eq(h[3], { old_start = 0, old = 0, new_start = 9, new = 2, removed = {} })
end)

test('<leader>rd draws added lines green and removed ones red where they were', function()
  local dir = fresh_repo()
  write(dir .. '/notes.md', (NOTES:gsub('We ship on Friday.', 'We ship on the 9th.'):gsub('Tests run nightly.\n', '')))
  vim.cmd.edit(dir .. '/notes.md')
  local d = require('review.diff')
  d.enabled = true
  review_ui.render(vim.api.nvim_get_current_buf())
  local marks = vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace('review_diff'), 0, -1, { details = true })
  local green, red = {}, {}
  for _, m in ipairs(marks) do
    if m[4].line_hl_group == 'DiffAdd' then table.insert(green, m[2] + 1) end
    for _, row in ipairs(m[4].virt_lines or {}) do table.insert(red, { m[2] + 1, vim.trim(row[1][1]), m[4].virt_lines_above }) end
  end
  eq(green, { 3 })
  -- git makes the change and the deletion after it one hunk: both red above.
  eq(red, { { 3, '- We ship on Friday.', true }, { 3, '- Tests run nightly.', true } })
  d.enabled = false
  review_ui.render(vim.api.nvim_get_current_buf())
  eq(#vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace('review_diff'), 0, -1, {}), 0)
end)

test('a deletion on its own sits below the line before it', function()
  local dir = fresh_repo()
  write(dir .. '/notes.md', (NOTES:gsub('## Risks\n', '')))
  vim.cmd.edit(dir .. '/notes.md')
  local d = require('review.diff')
  d.enabled = true
  review_ui.render(vim.api.nvim_get_current_buf())
  local marks = vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace('review_diff'), 0, -1, { details = true })
  eq(#marks, 1)
  eq({ marks[1][2] + 1, vim.trim(marks[1][4].virt_lines[1][1][1]), marks[1][4].virt_lines_above }, { 5, '- ## Risks', false })
  d.enabled = false
end)

test('an untracked file is all green', function()
  local dir = fresh_repo()
  write(dir .. '/new.md', 'one\ntwo\n')
  vim.cmd.edit(dir .. '/new.md')
  local d = require('review.diff')
  d.enabled = true
  review_ui.render(vim.api.nvim_get_current_buf())
  eq(#vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace('review_diff'), 0, -1, {}), 2)
  d.enabled = false
end)

test('<leader>rl toggles the thread list', function()
  local dir = fresh_repo()
  vim.cmd.edit(dir .. '/notes.md')
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  answer('Which Friday?')
  review_ui.comment()
  review_ui.list()
  eq(vim.fn.getqflist({ winid = 0 }).winid ~= 0, true, 'open')
  eq(vim.fn.getqflist({ items = 0 }).items[1].text, 't1 ben: Which Friday?')
  review_ui.list()
  eq(vim.fn.getqflist({ winid = 0 }).winid, 0, 'closed')
end)

-- ---- buttons ------------------------------------------------------------

-- A virtual row as the screen shows it: one string per cell, after a 4-cell gutter.
local function cells_of(row)
  local text = '    ' .. table.concat(vim.tbl_map(function(chunk) return chunk[1] end, row))
  local cells = {}
  for _, ch in ipairs(vim.fn.split(text, [[\zs]])) do
    table.insert(cells, ch)
    for _ = 2, vim.fn.strdisplaywidth(ch) do table.insert(cells, '') end
  end
  return cells, text
end

local function header_of(buf)
  local marks = vim.api.nvim_buf_get_extmarks(buf or 0, vim.api.nvim_create_namespace('review'), 0, -1, { details = true })
  return marks[1][4].virt_lines[1]
end

test('a header row has buttons, found by the column clicked', function()
  local dir = fresh_repo()
  vim.cmd.edit(dir .. '/notes.md')
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  answer('Which Friday?')
  review_ui.comment()
  local cells, text = cells_of(header_of())
  local function at(label)
    return vim.fn.strdisplaywidth(text:sub(1, text:find('[' .. label .. ']', 1, true))) + 1
  end
  eq({ review_ui.button_at(cells, at('reply')) }, { 't1', 'reply' })
  eq({ review_ui.button_at(cells, at('resolve')) }, { 't1', 'resolve' })
  eq({ review_ui.button_at(cells, at('collapse')) }, { 't1', 'collapse' })
  eq(review_ui.button_at(cells, 2), nil, 'the gutter is no button')
  eq(review_ui.button_at({ 'l', 'e', 't', ' ', '[', 'r', 'e', 'p', 'l', 'y', ']' }, 7), nil, 'text that is no header')
end)

test('collapse folds a thread to its header; expand brings it back', function()
  local dir, repo = fresh_repo()
  vim.cmd.edit(dir .. '/notes.md')
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  answer('Which Friday?')
  review_ui.comment()
  local buf = vim.api.nvim_get_current_buf()
  review_ui.act(buf, 't1', 'collapse')
  local marks, text = virt()
  eq(#marks[1][4].virt_lines, 1)
  has(text, '▸ t1')
  has(text, '1 comment')
  has(text, '[expand]')
  answer('The 9th?')
  review_ui.act(buf, 't1', 'reply')
  eq(#store.load(repo).threads[1].comments, 2, 'reply from a folded header')
  review_ui.act(buf, 't1', 'expand')
  has(select(2, virt()), 'ben: The 9th?')
  review_ui.act(buf, 't1', 'resolve')
  eq(store.load(repo).threads[1].resolved, true)
  review_ui.act(buf, 't1', 'reopen')
  eq(store.load(repo).threads[1].resolved, false)
end)

test('buttons keep their columns in every state', function()
  local dir = fresh_repo()
  vim.cmd.edit(dir .. '/notes.md')
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  answer('Which Friday?')
  review_ui.comment()
  local buf = vim.api.nvim_get_current_buf()
  local function columns()
    local _, text = cells_of(header_of(buf))
    local found = {}
    for _, label in ipairs({ 'reply', 'resolve', 'reopen', 'collapse', 'expand' }) do
      local at = text:find('[' .. label .. ']', 1, true)
      if at then found[label] = vim.fn.strdisplaywidth(text:sub(1, at)) end
    end
    return found
  end
  local open = columns()
  review_ui.act(buf, 't1', 'collapse')
  local folded = columns()
  eq(folded.reply, open.reply)
  eq(folded.resolve, open.resolve)
  eq(folded.expand, open.collapse)
  review_ui.act(buf, 't1', 'resolve')
  eq(columns().reopen, open.resolve)
  review_ui.act(buf, 't1', 'reopen')
  review_ui.act(buf, 't1', 'expand')
end)

test('review watch ends on SIGTERM, as when its Claude session ends', function()
  local dir = fresh_repo()
  watching(dir)
  local proc = watchers[#watchers]
  vim.wait(1000)
  proc:kill(15)
  local r = proc:wait(3000)
  eq(r.signal ~= 0 or r.code ~= 124, true, 'exited')
  eq(vim.uv.kill(proc.pid, 0) == 0, false, 'gone')
end)

for _, proc in ipairs(watchers) do
  proc:kill(9)
end
vim.fn.delete(tmp, 'rf')
print(('%d passed, %d failed'):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
