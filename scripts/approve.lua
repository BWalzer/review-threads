-- Reads a PreToolUse event on stdin; prints an allow decision only for a
-- `review` command that can do nothing but read or append to the threads.
local ok, e = pcall(vim.json.decode, io.read('*a'))
local cmd = ok and type(e) == 'table' and type(e.tool_input) == 'table' and e.tool_input.command or ''

-- `review reply tN <<'TAG'` + body + `TAG`: a quoted heredoc expands nothing,
-- but a body line equal to TAG would end it early and run the rest.
local function is_heredoc_reply()
  local tag, body, last = cmd:match("^review%s+reply%s+t%d+%s+<<%s*'([%w_]+)'\n(.-)\n?([^\n]*)\n?$")
  if not tag or vim.trim(last) ~= tag then
    return false
  end
  for _, line in ipairs(vim.split(body, '\n', { plain = true })) do
    if vim.trim(line) == tag then
      return false
    end
  end
  return true
end

local safe = cmd:match('^review%s+show%s*$')
  or cmd:match('^review%s+reply%s+t%d+%s+[%w%s%.,:!?%-]+$')
  or is_heredoc_reply()

if safe then
  io.write(vim.json.encode({
    hookSpecificOutput = {
      hookEventName = 'PreToolUse',
      permissionDecision = 'allow',
      permissionDecisionReason = 'review-threads: reads or answers a review thread',
    },
  }))
end
