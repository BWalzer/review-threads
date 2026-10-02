-- Review threads in Neovim (the review-threads Claude Code plugin links this
-- directory into nvim's package path). See lua/review/init.lua for the keys.
if vim.g.loaded_review_threads then
  return
end
vim.g.loaded_review_threads = true

-- Reload files changed outside nvim (Claude editing in the next pane); a
-- buffer with unsaved edits is left alone and nvim asks.
vim.opt.autoread = true
vim.api.nvim_create_autocmd({ 'FocusGained', 'BufEnter', 'CursorHold' }, {
  group = vim.api.nvim_create_augroup('review_threads_reload', {}),
  command = 'silent! checktime',
})

require('review').setup()
