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

-- Explicitly dismissed predictions, matched on content rather than position
-- so a suggestion stays rejected even when the lines shift.
local rejected = {} -- { { buf, original, replacement }, ... } most recent last
local REJECTED_MAX = 5

--- pred = { start_line, end_line, replacement } (absolute 1-indexed, inclusive)
function M.show(buf, pred, tick)
  M.dismiss()
  if pred.end_line > vim.api.nvim_buf_line_count(buf) then
    return
  end
  local original = vim.api.nvim_buf_get_lines(buf, pred.start_line - 1, pred.end_line, false)
  -- The user already said no to exactly this suggestion; stay quiet until
  -- the underlying lines change.
  local original_text = table.concat(original, "\n")
  local replacement_text = table.concat(pred.replacement, "\n")
  for _, r in ipairs(rejected) do
    if r.buf == buf and r.original == original_text and r.replacement == replacement_text then
      return
    end
  end
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
    on_accept = pred.on_accept,
    hint_buf = pred.hint_buf,
    tick = tick,
    jump_pos = { marks[1][1] + 1, marks[1][2] },
  }
  -- A cross-buffer prediction is invisible from where the user sits; leave a
  -- hint at their cursor line pointing at the file it lives in.
  if pred.hint_buf and pred.hint_buf ~= buf and vim.api.nvim_win_get_buf(0) == pred.hint_buf then
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    vim.api.nvim_buf_set_extmark(pred.hint_buf, ns, lnum - 1, 0, {
      virt_text = { { "» edit in " .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t"), "NextEditSign" } },
      virt_text_pos = "eol",
    })
  end
end

function M.visible()
  return current ~= nil
end

--- Re-render the pending prediction (placement depends on whether a
--- completion menu is open, so it changes when one closes).
function M.refresh()
  if current then
    local c = current
    M.show(c.buf, {
      start_line = c.start_line,
      end_line = c.end_line,
      replacement = c.replacement,
      on_accept = c.on_accept,
      hint_buf = c.hint_buf,
    }, c.tick)
  end
end

function M.dismiss()
  if not current then
    return
  end
  vim.api.nvim_buf_clear_namespace(current.buf, ns, 0, -1)
  if current.hint_buf and vim.api.nvim_buf_is_valid(current.hint_buf) then
    vim.api.nvim_buf_clear_namespace(current.hint_buf, ns, 0, -1)
  end
  current = nil
end

--- The buffer holding the pending prediction, or nil.
function M.buffer()
  return current and current.buf
end

--- Explicit user dismissal: like dismiss(), but remember the suggestion so
--- an identical one is not shown again. (Plain dismiss() is also called for
--- routine clearing — buffer changes, mode switches — where remembering
--- would wrongly blacklist suggestions the user never declined.)
function M.reject()
  if current and vim.api.nvim_buf_is_valid(current.buf) then
    local c = current
    local lines = vim.api.nvim_buf_get_lines(c.buf, c.start_line - 1, c.end_line, false)
    rejected[#rejected + 1] = {
      buf = c.buf,
      original = table.concat(lines, "\n"),
      replacement = table.concat(c.replacement, "\n"),
    }
    if #rejected > REJECTED_MAX then
      table.remove(rejected, 1)
    end
  end
  M.dismiss()
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
  else
    -- The prediction lives in another buffer: first accept goes there.
    vim.cmd("normal! m'")
    vim.api.nvim_win_set_buf(win, c.buf)
    pcall(vim.api.nvim_win_set_cursor, win, c.jump_pos)
    return true
  end
  M.dismiss()
  vim.api.nvim_buf_set_lines(c.buf, c.start_line - 1, c.end_line, false, c.replacement)
  -- Land the cursor at the end of the new text.
  if vim.api.nvim_win_get_buf(win) == c.buf then
    local last = math.min(c.start_line + math.max(#c.replacement, 1) - 1, vim.api.nvim_buf_line_count(c.buf))
    local col = #(vim.api.nvim_buf_get_lines(c.buf, last - 1, last, false)[1] or "")
    vim.api.nvim_win_set_cursor(win, { last, col })
  end
  if c.on_accept then
    pcall(c.on_accept)
  end
  return true
end

return M
