-- Review threads for one repository, kept in <git dir>/review-threads.json so
-- they are never committed and never show in a diff. Shared by the nvim side
-- (comment, reply, resolve) and the `review` CLI Claude runs (show, reply, watch).
--
-- A thread: { id, path (repo-relative), anchor (see anchor.lua),
--             comments = { { author = 'ben'|'claude', text, at } }, resolved,
--             seen (how many of its comments `review show` has shown Claude) }
local anchor = require('review.anchor')

local M = {}

local function git(dir, args)
  local r = vim.system(vim.list_extend({ 'git', '-C', dir }, args), { text = true }):wait()
  return r.code == 0 and vim.trim(r.stdout) or nil
end

--- The repository holding `dir`: `{ root, file, wait }`, or nil outside one.
--- `wait` holds the pid of the `review watch` listening for comments.
function M.repo(dir)
  local root = git(dir, { 'rev-parse', '--show-toplevel' })
  local gitdir = root and git(dir, { 'rev-parse', '--path-format=absolute', '--git-common-dir' })
  return gitdir and { root = root, file = gitdir .. '/review-threads.json', wait = gitdir .. '/review-wait.pid' } or nil
end

--- Whether a `review watch` (a Claude session's monitor) runs for this repo.
function M.is_listening(repo)
  local f = io.open(repo.wait, 'r')
  local pid = f and tonumber(f:read('*a'))
  if f then f:close() end
  return pid ~= nil and vim.uv.kill(pid, 0) == 0
end

function M.load(repo)
  local f = io.open(repo.file, 'r')
  if not f then
    return { next = 1, threads = {} }
  end
  local ok, book = pcall(vim.json.decode, f:read('*a'))
  f:close()
  return ok and type(book) == 'table' and book or { next = 1, threads = {} }
end

-- Written beside and renamed over, so a reader never sees half a file.
function M.save(repo, book)
  local tmp = repo.file .. '.tmp'
  local f = assert(io.open(tmp, 'w'))
  f:write(vim.json.encode(book))
  f:close()
  assert(os.rename(tmp, repo.file))
end

function M.find(book, id)
  for _, thread in ipairs(book.threads) do
    if thread.id == id then
      return thread
    end
  end
end

local function now()
  return os.date('!%Y-%m-%dT%H:%M:%SZ')
end

--- The file's lines on disk, or nil when it cannot be read.
function M.lines(repo, path)
  local f = io.open(repo.root .. '/' .. path, 'r')
  if not f then
    return nil
  end
  local text = f:read('*a')
  f:close()
  return anchor.lines_of(text)
end

--- Starts a thread on 1-based `line` of `lines` (the file `path`); the thread,
--- or nil and why not.
function M.add(repo, path, lines, line, text)
  local a = anchor.anchor_at(lines, line)
  if not a then
    return nil, ('%s has no line %d'):format(path, line)
  end
  if anchor.locate(a, lines).line ~= line then
    return nil, ("%s:%d can't be anchored reliably (blank, or repeated with the same surroundings); comment on a nearby distinctive line"):format(path, line)
  end
  local book = M.load(repo)
  local thread = {
    id = 't' .. book.next,
    path = path,
    anchor = a,
    comments = { { author = 'ben', text = text, at = now() } },
    resolved = false,
  }
  book.next = book.next + 1
  table.insert(book.threads, thread)
  M.save(repo, book)
  return thread
end

--- Adds a comment to thread `id`; the thread, or nil when there is none.
function M.comment(repo, id, author, text)
  local book = M.load(repo)
  local thread = M.find(book, id)
  if thread then
    table.insert(thread.comments, { author = author, text = text, at = now() })
    M.save(repo, book)
  end
  return thread
end

function M.set_resolved(repo, id, resolved)
  local book = M.load(repo)
  local thread = M.find(book, id)
  if thread then
    thread.resolved = resolved
    M.save(repo, book)
  end
  return thread
end

--- Open threads whose newest comment is Ben's and that Claude has not been shown.
function M.unseen(book)
  return vim.tbl_filter(function(t)
    return not t.resolved and t.comments[#t.comments].author == 'ben' and #t.comments > (t.seen or 0)
  end, book.threads)
end

--- Records that Claude has been shown every open thread as it stands.
function M.mark_seen(repo)
  local book = M.load(repo)
  local shown = M.unseen(book)
  for _, t in ipairs(shown) do
    t.seen = #t.comments
  end
  if #shown > 0 then
    M.save(repo, book)
  end
end

local OUTDATED = {
  missing = 'the commented line changed or is gone',
  ambiguous = 'the commented line now matches several places',
  weak = 'too little of its surroundings is left to place it',
}

--- One thread as text: where it is now (or why it is outdated), the lines
--- around it as they read now, and its comments.
function M.describe(thread, at, lines)
  local out = {}
  if at.line then
    table.insert(out, ('[%s] %s:%d'):format(thread.id, thread.path, at.line))
    for n = math.max(1, at.line - 2), math.min(#lines, at.line + 2) do
      table.insert(out, ('%s %4d | %s'):format(n == at.line and '>' or ' ', n, lines[n]))
    end
  else
    table.insert(out, ('[%s] %s (outdated: %s; was line %d)'):format(thread.id, thread.path, OUTDATED[at.reason], thread.anchor.hint))
    table.insert(out, '  was: ' .. thread.anchor.text)
  end
  for _, c in ipairs(thread.comments) do
    table.insert(out, ('  %s: %s'):format(c.author, (c.text:gsub('\n', '\n    '))))
  end
  return table.concat(out, '\n')
end

--- Where `thread` is in the file on disk now.
function M.place(repo, thread)
  local lines = M.lines(repo, thread.path)
  return lines and anchor.locate(thread.anchor, lines) or { reason = 'missing' }, lines
end

--- Every open thread, described for Claude.
function M.show(repo)
  local parts = {}
  for _, thread in ipairs(M.load(repo).threads) do
    if not thread.resolved then
      local at, lines = M.place(repo, thread)
      table.insert(parts, M.describe(thread, at, lines))
    end
  end
  if #parts == 0 then
    return 'No open review threads.'
  end
  table.insert(parts, 1, table.concat({
    "Open review threads: Ben's line comments on your work. Act on each, then answer",
    'it in the thread, saying what you changed or asking what you need:',
    '',
    "  review reply <id> <<'EOF'",
    '  your reply',
    '  EOF',
    '',
    'Keep the quoted heredoc: the text then reaches the thread exactly as written.',
    'Only Ben resolves threads. An outdated thread lost its line after an edit;',
    'work from what it was and the comments.',
  }, '\n'))
  return table.concat(parts, '\n\n')
end

return M
