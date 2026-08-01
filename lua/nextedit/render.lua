-- Turns a prediction into extmark specs. Small same-shaped changes render as
-- word-level inline diffs (changed words highlighted in place, insertions as
-- inline virtual text); everything else falls back to the block style, where
-- replaced lines are highlighted and the proposed lines appear below.
local M = {}

local INLINE_MAX_LINES = 3
-- When most of the new line is insertions, inline marks are noisier than the
-- block overlay; fall back.
local INLINE_MAX_INSERT_RATIO = 0.5

--- Split a line into word, whitespace and punctuation runs (byte-safe:
--- multibyte characters land in punctuation runs, never split mid-character).
local function split_tokens(line)
  local toks = {}
  local i = 1
  while i <= #line do
    local tok = line:match("^[%w_]+", i) or line:match("^%s+", i) or line:match("^[^%w_%s]+", i)
    toks[#toks + 1] = tok
    i = i + #tok
  end
  return toks
end

--- Inline word-diff marks for one replaced line, or nil when the block style
--- would read better.
local function inline_marks(row, old_line, new_line)
  if old_line == "" or new_line == "" then
    return nil
  end
  local a, b = split_tokens(old_line), split_tokens(new_line)
  local hunks = vim.diff(table.concat(a, "\n") .. "\n", table.concat(b, "\n") .. "\n", {
    result_type = "indices",
    algorithm = "minimal",
    ctxlen = 0,
  })
  if not hunks then
    return nil
  end
  local col, end_col = {}, {}
  local pos = 0
  for i, tok in ipairs(a) do
    col[i], end_col[i] = pos, pos + #tok
    pos = pos + #tok
  end
  local marks = {}
  local inserted = 0
  for _, h in ipairs(hunks) do
    local ai, ac, bi, bc = h[1], h[2], h[3], h[4]
    if ac > 0 then
      marks[#marks + 1] =
        { row, col[ai], { end_col = end_col[ai + ac - 1], hl_group = "NextEditOld" } }
    end
    if bc > 0 then
      local text = table.concat(b, "", bi, bi + bc - 1)
      inserted = inserted + #text
      local at = ac > 0 and end_col[ai + ac - 1] or (ai == 0 and 0 or end_col[ai])
      marks[#marks + 1] =
        { row, at, { virt_text = { { text, "NextEditNew" } }, virt_text_pos = "inline" } }
    end
  end
  if inserted / #new_line > INLINE_MAX_INSERT_RATIO then
    return nil
  end
  return marks
end

--- Block marks for one hunk: replaced lines highlighted whole, proposed lines
--- as virtual lines below (or above, for an insertion before the range).
local function block_marks(marks, start_row, replacement, ai, ac, bi, bc)
  for k = 0, ac - 1 do
    marks[#marks + 1] = { start_row + ai - 1 + k, 0, { line_hl_group = "NextEditOld" } }
  end
  if bc > 0 then
    local virt = {}
    for k = bi, bi + bc - 1 do
      local line = replacement[k]
      virt[#virt + 1] = { { line == "" and " " or line, "NextEditNew" } }
    end
    if ac > 0 then
      marks[#marks + 1] = { start_row + ai - 1 + ac - 1, 0, { virt_lines = virt } }
    elseif ai == 0 then
      marks[#marks + 1] = { start_row, 0, { virt_lines = virt, virt_lines_above = true } }
    else
      marks[#marks + 1] = { start_row + ai - 1, 0, { virt_lines = virt } }
    end
  end
end

--- Extmark specs ({row, col, opts}, 0-indexed) rendering `replacement` over
--- the buffer lines `original` that start at `start_row`.
function M.extmarks(original, replacement, start_row)
  local a = table.concat(original, "\n")
  local b = table.concat(replacement, "\n")
  local hunks = vim.diff(a == "" and a or a .. "\n", b == "" and b or b .. "\n", {
    result_type = "indices",
    algorithm = "patience",
    indent_heuristic = true,
    linematch = 10,
    ctxlen = 0,
  }) or {}
  local marks = {}
  for _, h in ipairs(hunks) do
    local ai, ac, bi, bc = h[1], h[2], h[3], h[4]
    local inline = nil
    if ac == bc and ac >= 1 and ac <= INLINE_MAX_LINES then
      inline = {}
      for k = 0, ac - 1 do
        local line_marks = inline_marks(start_row + ai - 1 + k, original[ai + k], replacement[bi + k])
        if not line_marks then
          inline = nil
          break
        end
        vim.list_extend(inline, line_marks)
      end
    end
    if inline then
      vim.list_extend(marks, inline)
    else
      block_marks(marks, start_row, replacement, ai, ac, bi, bc)
    end
  end
  return marks
end

return M
