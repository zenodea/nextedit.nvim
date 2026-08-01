-- Renders the pending prediction as a diff overlay and applies it. Rendering
-- is delegated to render.lua: word-level inline marks for small changes, a
-- block overlay (old lines highlighted, new lines below) otherwise.
local render = require("nextedit.render")

local M = {}

local ns = vim.api.nvim_create_namespace("nextedit")
local current = nil -- { buf, start_line, end_line, replacement, tick, jump_pos }

-- Predictions further than this many lines from the cursor are not applied
-- outright: the first accept jumps to them, the second applies.
local JUMP_DISTANCE = 5

--- Whether a completion menu is on screen. It floats over the lines right
--- below the cursor — where the preview normally renders — so the preview
--- flips above the change while one is open. `package.loaded` guards keep
--- this from force-loading lazy plugins.
local function completion_visible()
  if vim.fn.pumvisible() == 1 then
    return true
  end
  local cmp = package.loaded["cmp"]
  if cmp then
    local ok, visible = pcall(cmp.visible)
    if ok and visible then
      return true
    end
  end
  local blink = package.loaded["blink.cmp"]
  if blink then
    local ok, visible = pcall(blink.is_visible)
    if ok and visible then
      return true
    end
  end
  return false
end

--- pred = { start_line, end_line, replacement } (absolute 1-indexed, inclusive)
function M.show(buf, pred, tick)
  M.dismiss()
  if pred.end_line > vim.api.nvim_buf_line_count(buf) then
    return
  end
  local original = vim.api.nvim_buf_get_lines(buf, pred.start_line - 1, pred.end_line, false)
  local marks = render.extmarks(original, pred.replacement, pred.start_line - 1, completion_visible())
  if #marks == 0 then
    return
  end
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, m[1], m[2], m[3])
  end
  -- A sign marks the first changed line, so a prediction outside the
  -- immediate eye line is still discoverable.
  vim.api.nvim_buf_set_extmark(buf, ns, marks[1][1], 0, {
    sign_text = "»",
    sign_hl_group = "NextEditSign",
  })
  current = {
    buf = buf,
    start_line = pred.start_line,
    end_line = pred.end_line,
    replacement = pred.replacement,
    tick = tick,
    jump_pos = { marks[1][1] + 1, marks[1][2] },
  }
end

function M.visible()
  return current ~= nil
end

--- Re-render the pending prediction (placement depends on whether a
--- completion menu is open, so it changes when one closes).
function M.refresh()
  if current then
    local c = current
    M.show(c.buf, { start_line = c.start_line, end_line = c.end_line, replacement = c.replacement }, c.tick)
  end
end

function M.dismiss()
  if not current then
    return
  end
  vim.api.nvim_buf_clear_namespace(current.buf, ns, 0, -1)
  current = nil
end

--- Accept the pending prediction: jump to it when it is far from the cursor,
--- apply it otherwise. Returns true if the key was consumed.
function M.accept()
  if not current then
    return false
  end
  local c = current
  -- The buffer must not have changed since the prediction was made.
  if not vim.api.nvim_buf_is_valid(c.buf) or vim.b[c.buf].changedtick ~= c.tick then
    M.dismiss()
    return false
  end
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) == c.buf then
    local lnum = vim.api.nvim_win_get_cursor(win)[1]
    if math.max(c.start_line - lnum, lnum - c.end_line) > JUMP_DISTANCE then
      vim.cmd("normal! m'") -- <C-o> returns to where the user was
      pcall(vim.api.nvim_win_set_cursor, win, c.jump_pos)
      return true
    end
  end
  M.dismiss()
  vim.api.nvim_buf_set_lines(c.buf, c.start_line - 1, c.end_line, false, c.replacement)
  -- Land the cursor at the end of the new text.
  if vim.api.nvim_win_get_buf(win) == c.buf then
    local last = math.min(c.start_line + math.max(#c.replacement, 1) - 1, vim.api.nvim_buf_line_count(c.buf))
    local col = #(vim.api.nvim_buf_get_lines(c.buf, last - 1, last, false)[1] or "")
    vim.api.nvim_win_set_cursor(win, { last, col })
  end
  return true
end

return M
