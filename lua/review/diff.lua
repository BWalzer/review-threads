-- A GitHub-style diff over the whole file: lines added or changed since HEAD
-- are green, lines removed come back as red virtual lines where they were.
-- Toggled with <leader>rd; follows the file as Claude edits it.
local M = {}

local ns = vim.api.nvim_create_namespace('review_diff')
M.enabled = false

--- Hunks of `git diff -U0` text: `{ old_start, old, new_start, new, removed = { lines } }`.
function M.hunks(diff)
  local hunks, hunk = {}, nil
  for _, line in ipairs(vim.split(diff, '\n', { plain = true })) do
    local os_, oc, ns_, nc = line:match('^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@')
    if os_ then
      hunk = {
        old_start = tonumber(os_), old = oc == '' and 1 or tonumber(oc),
        new_start = tonumber(ns_), new = nc == '' and 1 or tonumber(nc),
        removed = {},
      }
      table.insert(hunks, hunk)
    elseif hunk and line:sub(1, 1) == '-' and line:sub(1, 3) ~= '---' then
      table.insert(hunk.removed, line:sub(2))
    end
  end
  return hunks
end

local function git(root, args)
  local r = vim.system(vim.list_extend({ 'git', '-C', root }, args), { text = true }):wait()
  return r.code, r.stdout or ''
end

--- Draws the diff of `path` (repo-relative, in `root`) on buffer `buf`, its
--- removed lines padded to `width` cells so their red runs the window across.
function M.render(buf, root, path, width)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if not M.enabled then
    return
  end
  local count = vim.api.nvim_buf_line_count(buf)

  -- Untracked: every line is new.
  if git(root, { 'ls-files', '--error-unmatch', '--', path }) ~= 0 then
    for row = 0, count - 1 do
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { line_hl_group = 'DiffAdd', sign_text = '+', sign_hl_group = 'DiffAdd' })
    end
    return
  end

  local _, diff = git(root, { 'diff', '--no-color', '--no-ext-diff', '-U0', 'HEAD', '--', path })
  for _, h in ipairs(M.hunks(diff)) do
    for row = h.new_start, h.new_start + h.new - 1 do
      if row <= count then
        vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, { line_hl_group = 'DiffAdd', sign_text = '+', sign_hl_group = 'DiffAdd' })
      end
    end
    if #h.removed > 0 then
      local virt = vim.tbl_map(function(text)
        local shown = '- ' .. text:gsub('\t', '    ')
        return { { shown .. string.rep(' ', math.max(0, width - vim.fn.strdisplaywidth(shown))), 'DiffDelete' } }
      end, h.removed)
      -- A pure deletion sits after new line `new_start`; a change sits above
      -- its new lines. Line 0 means the top of the file.
      local below = h.new == 0 and h.new_start > 0
      local row = below and h.new_start - 1 or math.max(0, h.new_start - 1)
      vim.api.nvim_buf_set_extmark(buf, ns, math.min(row, count - 1), 0, { virt_lines = virt, virt_lines_above = not below })
    end
  end
end

return M
