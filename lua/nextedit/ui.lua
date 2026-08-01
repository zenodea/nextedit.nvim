-- Renders the pending prediction as a diff overlay and applies it. Rendering
-- is delegated to render.lua: word-level inline marks for small changes, a
-- block overlay (old lines highlighted, new lines below) otherwise.
local render = require("nextedit.render")

local M = {}

local ns = vim.api.nvim_create_namespace("nextedit")
local current = nil -- { buf, start_line, end_line, replacement, tick }

--- pred = { start_line, end_line, replacement } (absolute 1-indexed, inclusive)
function M.show(buf, pred, tick)
  M.dismiss()
  if pred.end_line > vim.api.nvim_buf_line_count(buf) then
    return
  end
  local original = vim.api.nvim_buf_get_lines(buf, pred.start_line - 1, pred.end_line, false)
  local marks = render.extmarks(original, pred.replacement, pred.start_line - 1)
  if #marks == 0 then
    return
  end
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, m[1], m[2], m[3])
  end
  current = {
    buf = buf,
    start_line = pred.start_line,
    end_line = pred.end_line,
    replacement = pred.replacement,
    tick = tick,
  }
end

function M.visible()
  return current ~= nil
end

function M.dismiss()
  if not current then
    return
  end
  vim.api.nvim_buf_clear_namespace(current.buf, ns, 0, -1)
  current = nil
end

--- Apply the pending prediction. Returns true if one was applied.
function M.accept()
  if not current then
    return false
  end
  local c = current
  M.dismiss()
  -- The buffer must not have changed since the prediction was made.
  if not vim.api.nvim_buf_is_valid(c.buf) or vim.b[c.buf].changedtick ~= c.tick then
    return false
  end
  vim.api.nvim_buf_set_lines(c.buf, c.start_line - 1, c.end_line, false, c.replacement)
  -- Land the cursor at the end of the new text.
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) == c.buf then
    local last = math.min(c.start_line + math.max(#c.replacement, 1) - 1, vim.api.nvim_buf_line_count(c.buf))
    local col = #(vim.api.nvim_buf_get_lines(c.buf, last - 1, last, false)[1] or "")
    vim.api.nvim_win_set_cursor(win, { last, col })
  end
  return true
end

return M
