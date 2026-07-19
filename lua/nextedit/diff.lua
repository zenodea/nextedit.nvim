-- Tracks what the user has been changing: on every prediction cycle we diff
-- the buffer against its previous snapshot and keep the last few hunks.
-- This history is what lets the model predict a *next* edit rather than
-- just completing text at the cursor.
local M = {}

local MAX_EDITS = 6
local state = {} -- buf -> { snapshot = string, edits = { string, ... } }

local function buffer_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n"
end

--- Record the change since the last call and return the recent-edit history.
function M.take(buf)
  local text = buffer_text(buf)
  local s = state[buf]
  if not s then
    state[buf] = { snapshot = text, edits = {} }
    return {}
  end
  if text ~= s.snapshot then
    local hunks = vim.diff(s.snapshot, text, { ctxlen = 2 })
    if hunks and hunks ~= "" then
      table.insert(s.edits, hunks)
      if #s.edits > MAX_EDITS then
        table.remove(s.edits, 1)
      end
    end
    s.snapshot = text
  end
  return s.edits
end

function M.forget(buf)
  state[buf] = nil
end

return M
