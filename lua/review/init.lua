-- Review threads in nvim: comment on a line, see Claude's replies under it.
--
--   <leader>rc  comment on the cursor line      <leader>rx  resolve / reopen a thread
--   <leader>rr  reply to a thread               <leader>rz  collapse / expand a thread
--   <leader>rl  open threads list (toggle)      <leader>rd  diff against HEAD (toggle)
--
-- Each thread's header also has buttons to click: [reply] [resolve] [collapse]
-- [expand] [reopen]. A resolved thread stays as one dim line, so it can be
-- reopened where it was.
--
-- Threads live in <git dir>/review-threads.json (store.lua). Each Claude Code
-- session with the plugin runs `review watch` as a monitor, which tells Claude
-- when a comment of Ben's is new to it; Claude then runs `review show` /
-- `review reply` (cli.lua). nvim never types into Claude's terminal, and
-- redraws when the thread file changes.
local anchor = require('review.anchor')
local diff = require('review.diff')
local store = require('review.store')

local M = {}
local ns = vim.api.nvim_create_namespace('review')
local watched = {}
local collapsed = {} -- thread id → true while folded to its header

local function notify(msg, level)
  vim.notify('review: ' .. msg, level or vim.log.levels.INFO)
end

local repos = {} -- directory → repo (false outside one): git runs once per directory

--- The repo and repo-relative path of buffer `buf`, or nil.
local function where(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' or vim.bo[buf].buftype ~= '' then
    return nil
  end
  local real = vim.uv.fs_realpath(name) or name
  local dir = vim.fs.dirname(real)
  if repos[dir] == nil then
    repos[dir] = store.repo(dir) or false
  end
  local repo = repos[dir]
  if not repo or real:sub(1, #repo.root + 1) ~= repo.root .. '/' then
    return nil
  end
  return repo, real:sub(#repo.root + 2)
end

-- Threads of `path` (open ones, or all), each with where it sits in `lines` now.
local function placed(repo, path, lines, with_resolved)
  local out = {}
  for _, thread in ipairs(store.load(repo).threads) do
    if thread.path == path and (with_resolved or not thread.resolved) then
      table.insert(out, { thread = thread, at = anchor.locate(thread.anchor, lines) })
    end
  end
  return out
end

--- `text` broken into lines of at most `width` cells, at spaces where it can.
function M.wrap(text, width)
  local out = {}
  for _, para in ipairs(vim.split(text, '\n', { plain = true })) do
    local line = ''
    for word in para:gmatch('%S+') do
      while vim.fn.strdisplaywidth(word) > width do
        if line ~= '' then
          table.insert(out, line)
          line = ''
        end
        local cut = vim.fn.strcharpart(word, 0, width)
        table.insert(out, cut)
        word = vim.fn.strcharpart(word, vim.fn.strchars(cut))
      end
      local joined = line == '' and word or line .. ' ' .. word
      if vim.fn.strdisplaywidth(joined) > width then
        table.insert(out, line)
        line = word
      else
        line = joined
      end
    end
    table.insert(out, line)
  end
  return out
end

--- The text width of the window showing `buf` (its first, else the current).
function M.text_width(buf)
  local win = vim.fn.bufwinid(buf)
  local info = vim.fn.getwininfo(win ~= -1 and win or vim.api.nvim_get_current_win())[1]
  return math.max(20, info.width - info.textoff)
end

function M.render(buf)
  if not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local repo, path = where(buf)
  if not repo then
    return
  end
  M.watch(repo)
  local width = M.text_width(buf)
  diff.render(buf, repo.root, path, width)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for _, one in ipairs(placed(repo, path, lines, true)) do
    local t, at = one.thread, one.at
    local virt = {}
    local function add(lead, rest, text, hl)
      for k, piece in ipairs(M.wrap(text, width - vim.fn.strdisplaywidth(lead))) do
        table.insert(virt, { { (k == 1 and lead or rest) .. piece, hl } })
      end
    end
    -- The header: mark, id, then three button slots that never move, whatever
    -- the state: [reply] [resolve|reopen] [collapse|expand]; a slot a state has
    -- no button for is blank. The summary comes last. M.button_at finds them.
    local function header(mark, hl, slots, summary)
      local row = { { ('  %s %-4s  '):format(mark, t.id), hl } }
      for k, label in ipairs(slots) do
        local width = ({ 7, 9, 10 })[k] -- [reply], [resolve], [collapse]
        local shown = label and '[' .. label .. ']' or ''
        table.insert(row, { shown, 'Special' })
        table.insert(row, { string.rep(' ', width - #shown + 1), hl })
      end
      table.insert(row, { summary, hl })
      table.insert(virt, row)
    end
    local count = ('%d comment%s'):format(#t.comments, #t.comments == 1 and '' or 's')
    local outdated = at.line and '' or ' · outdated'
    local hl = at.line and 'DiagnosticInfo' or 'DiagnosticWarn'
    if t.resolved then
      header('✓', 'Comment', { false, 'reopen', false }, 'resolved · ' .. count)
    elseif collapsed[t.id] then
      header(at.line and '▸' or '⚠', hl, { 'reply', 'resolve', 'expand' }, count .. outdated)
    else
      header(at.line and '┌' or '⚠', hl, { 'reply', 'resolve', 'collapse' }, '')
      if not at.line then
        add('  │ ', '  │ ', ('outdated (was line %d): %s'):format(t.anchor.hint, t.anchor.text), 'DiagnosticWarn')
      end
      for _, c in ipairs(t.comments) do
        local lead = ('  │ %s: '):format(c.author)
        add(lead, '  │ ' .. string.rep(' ', #c.author + 2), c.text, c.author == 'claude' and 'DiagnosticHint' or 'Comment')
      end
    end
    vim.api.nvim_buf_set_extmark(buf, ns, (at.line or 1) - 1, 0, {
      virt_lines = virt,
      virt_lines_above = at.line == nil,
    })
  end
end

local function render_all()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    M.render(vim.api.nvim_win_get_buf(win))
  end
end

--- Redraw when the thread file changes (Claude replied, another nvim commented).
function M.watch(repo)
  if watched[repo.file] then
    return
  end
  local w = assert(vim.uv.new_fs_event())
  watched[repo.file] = w
  w:start(vim.fs.dirname(repo.file), {}, vim.schedule_wrap(function(_, file)
    if file == 'review-threads.json' then
      render_all()
    end
  end))
end

-- ---- Claude listening --------------------------------------------------

--- Says the comment is saved, and warns when no `review watch` will pick it up.
local function told(repo, what)
  if store.is_listening(repo) then
    notify(what .. '; Claude will pick it up')
  else
    notify(what .. ", but no Claude session is listening: start Claude Code in this repo with the review-threads plugin", vim.log.levels.WARN)
  end
end

-- ---- actions ------------------------------------------------------------

--- The thread the cursor is on, else a pick among the file's threads (open
--- ones, or all with `with_resolved`).
local function pick(prompt, fn, with_resolved)
  local repo, path = where(0)
  if not repo then
    return notify('this buffer is not a file in a git repository', vim.log.levels.WARN)
  end
  local here = placed(repo, path, vim.api.nvim_buf_get_lines(0, 0, -1, false), with_resolved)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local on_line = vim.tbl_filter(function(one) return one.at.line == row end, here)
  if #on_line == 1 then
    return fn(repo, on_line[1].thread)
  end
  local choices = #on_line > 1 and on_line or here
  if #choices == 0 then
    return notify('no open threads in this file')
  end
  vim.ui.select(choices, {
    prompt = prompt,
    format_item = function(one)
      return ('%s %s: %s'):format(one.thread.id, one.at.line and 'line ' .. one.at.line or 'outdated', one.thread.comments[1].text)
    end,
  }, function(one)
    if one then fn(repo, one.thread) end
  end)
end

function M.comment()
  local repo, path = where(0)
  if not repo then
    return notify('this buffer is not a file in a git repository', vim.log.levels.WARN)
  end
  if vim.bo.modified then
    return notify('save first: Claude reads the file on disk', vim.log.levels.WARN)
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  vim.ui.input({ prompt = ('Comment on %s:%d: '):format(path, row) }, function(text)
    if not text or vim.trim(text) == '' then return end
    local thread, err = store.add(repo, path, vim.api.nvim_buf_get_lines(0, 0, -1, false), row, vim.trim(text))
    if not thread then
      return notify(err, vim.log.levels.WARN)
    end
    M.render(0)
    told(repo, ('%s saved'):format(thread.id))
  end)
end

local function reply_to(repo, thread)
  vim.ui.input({ prompt = ('Reply to %s: '):format(thread.id) }, function(text)
    if not text or vim.trim(text) == '' then return end
    store.comment(repo, thread.id, 'ben', vim.trim(text))
    render_all()
    told(repo, ('reply in %s saved'):format(thread.id))
  end)
end

local function set_resolved(repo, thread, resolved)
  store.set_resolved(repo, thread.id, resolved)
  render_all()
  notify((resolved and 'resolved ' or 'reopened ') .. thread.id)
end

local function toggle_collapsed(thread)
  collapsed[thread.id] = not collapsed[thread.id] or nil
  render_all()
end

function M.reply()
  pick('Reply to: ', reply_to)
end

--- Resolves the thread on the cursor line, or reopens it when it is resolved.
function M.resolve()
  pick('Resolve or reopen: ', function(repo, thread)
    set_resolved(repo, thread, not thread.resolved)
  end, true)
end

function M.collapse()
  pick('Collapse or expand: ', function(_, thread) toggle_collapsed(thread) end)
end

-- ---- buttons --------------------------------------------------------------

local ACTIONS = { 'reply', 'resolve', 'collapse', 'expand', 'reopen' }

--- The thread and button under column `col` of a drawn row, given as its
--- screen cells (one string each), or nil. Found by what is drawn: a header
--- row reads `<mark> t<n> ... [button] [button]`.
function M.button_at(cells, col)
  local text = table.concat(vim.tbl_map(function(c)
    return #c == 1 and c or (c == '' and ' ' or '?')
  end, cells))
  local id = text:match('^%s*%?%s(t%d+)[%s?]')
  if not id then
    return nil
  end
  for _, action in ipairs(ACTIONS) do
    local from, to = text:find('[' .. action .. ']', 1, true)
    if from and col >= from and col <= to then
      return id, action
    end
  end
end

--- Runs a button's action on thread `id` of the file in buffer `buf`.
function M.act(buf, id, action)
  local repo = where(buf)
  local thread = repo and store.find(store.load(repo), id)
  if not thread then
    return
  end
  if action == 'reply' then
    reply_to(repo, thread)
  elseif action == 'resolve' or action == 'reopen' then
    set_resolved(repo, thread, action == 'resolve')
  else
    toggle_collapsed(thread)
  end
end

-- A click on a button acts; any other click is an ordinary click.
local function click()
  local p = vim.fn.getmousepos()
  local info = p.winid ~= 0 and vim.fn.getwininfo(p.winid)[1]
  if not info then
    return '<LeftMouse>'
  end
  local cells = {}
  for c = info.wincol, info.wincol + info.width - 1 do
    table.insert(cells, vim.fn.screenstring(p.screenrow, c))
  end
  local id, action = M.button_at(cells, p.screencol - info.wincol + 1)
  if not id then
    return '<LeftMouse>'
  end
  vim.schedule(function()
    vim.api.nvim_set_current_win(p.winid)
    M.act(vim.api.nvim_win_get_buf(p.winid), id, action)
  end)
  return ''
end

function M.reopen()
  local repo = where(0)
  if not repo then
    return notify('this buffer is not a file in a git repository', vim.log.levels.WARN)
  end
  local done = vim.tbl_filter(function(t) return t.resolved end, store.load(repo).threads)
  vim.ui.select(done, {
    prompt = 'Reopen: ',
    format_item = function(t) return ('%s %s: %s'):format(t.id, t.path, t.comments[1].text) end,
  }, function(t)
    if not t then return end
    store.set_resolved(repo, t.id, false)
    render_all()
  end)
end

local LIST = 'Review threads'

--- The open threads in the quickfix list, or closes it when it shows them.
function M.list()
  local qf = vim.fn.getqflist({ title = 0, winid = 0 })
  if qf.winid ~= 0 and qf.title == LIST then
    return vim.cmd('cclose')
  end
  local repo = where(0) or store.repo(vim.uv.cwd())
  if not repo then
    return notify('not in a git repository', vim.log.levels.WARN)
  end
  local items = {}
  for _, thread in ipairs(store.load(repo).threads) do
    if not thread.resolved then
      local at = store.place(repo, thread)
      local last = thread.comments[#thread.comments]
      table.insert(items, {
        filename = repo.root .. '/' .. thread.path,
        lnum = at.line or 1,
        text = ('%s%s %s: %s'):format(thread.id, at.line and '' or ' [outdated]', last.author, last.text),
      })
    end
  end
  vim.fn.setqflist({}, ' ', { title = LIST, items = items })
  vim.cmd(#items > 0 and 'copen' or 'cclose')
  if #items == 0 then notify('no open threads') end
end

function M.setup()
  local map = function(lhs, fn, desc) vim.keymap.set('n', lhs, fn, { desc = 'review: ' .. desc }) end
  map('<leader>rc', M.comment, 'comment on this line')
  map('<leader>rr', M.reply, 'reply to a thread')
  map('<leader>rx', M.resolve, 'resolve / reopen a thread')
  map('<leader>rz', M.collapse, 'collapse / expand a thread')
  vim.keymap.set('n', '<LeftMouse>', click, { expr = true, desc = 'review: buttons on threads' })
  map('<leader>rl', M.list, 'open threads list (toggle)')
  map('<leader>rd', function()
    diff.enabled = not diff.enabled
    render_all()
    notify(diff.enabled and 'diff against HEAD on' or 'diff off')
  end, 'diff against HEAD (toggle)')
  vim.api.nvim_create_user_command('ReviewReopen', M.reopen, {})

  vim.api.nvim_create_autocmd({ 'BufWinEnter', 'BufReadPost', 'BufWritePost', 'FileChangedShellPost', 'TextChanged' }, {
    group = vim.api.nvim_create_augroup('review', {}),
    callback = function(e) M.render(e.buf) end,
  })
  vim.api.nvim_create_autocmd({ 'WinResized', 'VimResized' }, {
    group = 'review',
    callback = render_all,
  })
end

return M
