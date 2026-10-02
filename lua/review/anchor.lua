-- Anchors: where a review thread sits in a file, found again by content after
-- edits. Pure: no I/O. The rule is to refuse rather than guess: a thread that
-- cannot be placed with confidence is outdated, never moved to a likely line.
local M = {}

local CONTEXT = 2

local function trim_end(s)
  return (s:gsub('%s+$', ''))
end

local function same(a, b)
  return a ~= nil and trim_end(a) == trim_end(b)
end

--- A line that says nothing alone: blank, or only brackets and punctuation.
function M.is_trivial(line)
  return line:gsub('[%s{}()%[%];,.:\'"`<>/*#%-]', '') == ''
end

--- A file's text as lines, without the empty one after a final newline.
function M.lines_of(text)
  local lines = vim.split(text, '\n', { plain = true })
  for i, line in ipairs(lines) do
    lines[i] = line:gsub('\r$', '')
  end
  if #lines > 1 and lines[#lines] == '' then
    table.remove(lines)
  end
  return lines
end

--- The anchor for 1-based `line` of `lines`, or nil when it is out of range.
function M.anchor_at(lines, line)
  local text = lines[line]
  if text == nil or line < 1 then
    return nil
  end
  return {
    text = text,
    before = vim.list_slice(lines, math.max(1, line - CONTEXT), line - 1),
    after = vim.list_slice(lines, line + 1, line + CONTEXT),
    hint = line,
  }
end

--- Finds the anchor's line in `lines` by content: `{ line = n }`, or
--- `{ reason = 'missing' | 'ambiguous' | 'weak' }` when it is outdated.
---
--- Found when exactly one occurrence of the line has its whole recorded context
--- around it, or when the line occurs once, says something on its own, and at
--- least one non-trivial context line still sits beside it.
function M.locate(anchor, lines)
  local candidates = {}
  for i, line in ipairs(lines) do
    if same(line, anchor.text) then
      table.insert(candidates, i)
    end
  end

  if #candidates == 0 then
    return { reason = 'missing' }
  end

  local context = vim.list_extend(vim.list_extend({}, anchor.before), anchor.after)
  local has_substance = not M.is_trivial(anchor.text)
  for _, line in ipairs(context) do
    has_substance = has_substance or not M.is_trivial(line)
  end

  -- The context lines that still sit beside candidate `at`.
  local function matches_of(at)
    local found, all = {}, true
    for k, line in ipairs(anchor.before) do
      local ok = same(lines[at - #anchor.before + k - 1], line)
      all = all and ok
      if ok then table.insert(found, line) end
    end
    for k, line in ipairs(anchor.after) do
      local ok = same(lines[at + k], line)
      all = all and ok
      if ok then table.insert(found, line) end
    end
    return found, all
  end

  local whole = vim.tbl_filter(function(at)
    local _, all = matches_of(at)
    return all
  end, candidates)

  if #whole == 1 and has_substance then
    return { line = whole[1] }
  end
  if #whole > 1 or #candidates > 1 then
    return { reason = 'ambiguous' }
  end

  local only = candidates[1]
  local found = matches_of(only)
  local backed = vim.tbl_contains(found, function(line) return not M.is_trivial(line) end, { predicate = true })
  local alone = #context == 0 and not M.is_trivial(anchor.text)

  if not M.is_trivial(anchor.text) and (backed or alone) then
    return { line = only }
  end
  return { reason = 'weak' }
end

return M
