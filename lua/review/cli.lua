-- `review`: the review threads from a shell, for Claude. Run by bin/review as
-- `nvim --clean -l cli.lua <args>`.
--
--   review show                open threads, with their lines as they read now;
--                              marks them seen
--   review reply <id> <<'EOF'  answer a thread as Claude, the text on stdin
--   review reply <id> <text>   the same, the text as arguments
--   review watch               runs for the session (the plugin's monitor):
--                              prints one line each time Ben leaves a comment
--                              Claude has not seen
local lib = vim.fs.dirname(vim.fs.dirname(vim.fs.abspath(arg[0])))
package.path = lib .. '/?.lua;' .. lib .. '/?/init.lua;' .. package.path

local store = require('review.store')

local function fail(msg)
  io.stderr:write('review: ' .. msg .. '\n')
  os.exit(1)
end

local command = arg[1]
local repo = store.repo(vim.uv.cwd())

-- Sleeps while letting Neovim's event loop run: a blocking sleep would hold
-- off SIGTERM, and the watcher would outlive the Claude session that started
-- it. Exits once orphaned, as a backstop for a parent that died hard.
local parent = vim.uv.os_getppid()
local function nap(ms)
  vim.wait(ms, function() return false end, 1000)
  if vim.uv.os_getppid() ~= parent then
    os.exit(0)
  end
end

if command == 'watch' then
  -- A session outside a repository has no threads: stay quiet, cheaply.
  while not repo do
    nap(60 * 1000)
  end
  local pid = tostring(vim.fn.getpid())
  local announced = {} -- thread id → comment count already announced
  while true do
    -- Claim the pid file unless another live watcher holds it, so nvim can
    -- tell someone is listening (store.is_listening).
    local f = io.open(repo.wait, 'r')
    local holder = f and f:read('*a')
    if f then f:close() end
    if holder ~= pid and not store.is_listening(repo) then
      f = io.open(repo.wait, 'w')
      if f then f:write(pid); f:close() end
    end

    local new = {}
    for _, t in ipairs(store.unseen(store.load(repo))) do
      if #t.comments > (announced[t.id] or 0) then
        table.insert(new, t.id)
        announced[t.id] = #t.comments
      end
    end
    if #new > 0 then
      io.write(('Ben left new review comments on %s. Run `review show`, address them, and answer each with `review reply`.\n'):format(table.concat(new, ', ')))
      io.stdout:flush()
    end
    nap(2000)
  end
end

if not repo then
  fail('not in a git repository')
end

if command == 'show' then
  print(store.show(repo))
  store.mark_seen(repo)
elseif command == 'reply' then
  local id = arg[2]
  local text = table.concat(vim.list_slice(arg, 3), ' ')
  if vim.trim(text) == '' then
    text = io.read('*a') or ''
  end
  if not id or vim.trim(text) == '' then
    fail("usage: review reply <id> <<'EOF' (text) EOF")
  end
  if not store.comment(repo, id, 'claude', vim.trim(text)) then
    local ids = vim.tbl_map(function(t) return t.id end, store.load(repo).threads)
    fail(('no thread %s; threads here: %s'):format(id, #ids > 0 and table.concat(ids, ', ') or 'none'))
  end
  print(('Replied in %s. It stays open until Ben resolves it.'):format(id))
else
  fail('usage: review show | review reply <id> | review watch')
end
