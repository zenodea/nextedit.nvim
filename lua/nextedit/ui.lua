-- Renders the pending prediction as a line-based diff overlay and applies it:
-- the lines that would change are highlighted, the proposed lines appear as
-- virtual lines below them.
local M = {}

local ns = vim.api.nvim_create_namespace("nextedit")
local current = nil -- { buf, start_line, end_line, replacement, tick }

--- pred = { start_line, end_line, replacement } (absolute 1-indexed, inclusive)
function M.show(buf, pred, tick)
  M.dismiss()
  if pred.end_line > vim.api.nvim_buf_line_count(buf) then
    return
  end
  -- Mark the lines that would be replaced.
  for lnum = pred.start_line, pred.end_line do
    vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, { line_hl_group = "NextEditOld" })
  end
  -- Show the proposed lines below the range (none for a pure deletion).
  if #pred.replacement > 0 then
    local virt = {}
    for _, line in ipairs(pred.replacement) do
      table.insert(virt, { { line == "" and " " or line, "NextEditNew" } })
    end
    vim.api.nvim_buf_set_extmark(buf, ns, pred.end_line - 1, 0, { virt_lines = virt })
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
