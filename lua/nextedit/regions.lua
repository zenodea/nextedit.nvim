-- Finds lines elsewhere in the file that the user's recent edits probably
-- affect next: identifiers the edits removed or replaced (an old function
-- name, say) still occur there. Those lines are sent as extra regions the
-- model may target, which is what lets a prediction land far outside the
-- cursor excerpt — the UI then offers a tab-to-jump.
local M = {}

local MAX_REGIONS = 3
local CONTEXT = 3
local MAX_RECENT = 3 -- only mine the newest edits; old ones are stale signal

-- Words that appear in diffs constantly without identifying anything.
local STOPWORDS = {}
for word in ("return local function const import from self this true false nil none null "
  .. "end then else elseif public private static void int string bool let var pub use def class"):gmatch("%S+") do
  STOPWORDS[word] = true
end

--- Identifiers present in the diffs' removed lines but absent from their
--- added lines: things whose remaining occurrences likely need the same
--- treatment.
local function stale_tokens(edits)
  local removed, added = {}, {}
  local first = math.max(1, #edits - MAX_RECENT + 1)
  for i = first, #edits do
    for line in edits[i].diff:gmatch("[^\n]+") do
      local kind = line:sub(1, 1)
      local bucket = kind == "-" and removed or kind == "+" and added or nil
      if bucket and not line:find("^[-+][-+][-+]") then
        for token in line:sub(2):gmatch("[%a_][%w_][%w_]+") do
          if not STOPWORDS[token:lower()] then
            bucket[token] = true
          end
        end
      end
    end
  end
  local out = {}
  for token in pairs(removed) do
    if not added[token] then
      out[#out + 1] = token
    end
  end
  return out
end

--- Up to MAX_REGIONS excerpts ({ start, lines }) of buffer lines outside
--- [first, last] that still contain an identifier the recent edits removed.
function M.find(buf, edits, first, last)
  local tokens = stale_tokens(edits)
  if #tokens == 0 then
    return {}
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local regions = {}
  for lnum, line in ipairs(lines) do
    if lnum < first or lnum > last then
      local hit = false
      for _, token in ipairs(tokens) do
        if line:find(token, 1, true) then
          hit = true
          break
        end
      end
      if hit then
        local s, e = math.max(1, lnum - CONTEXT), math.min(#lines, lnum + CONTEXT)
        local prev = regions[#regions]
        if prev and s <= prev.stop + 1 then
          prev.stop = math.max(prev.stop, e)
        elseif #regions < MAX_REGIONS then
          regions[#regions + 1] = { start = s, stop = e }
        end
      end
    end
  end
  for _, r in ipairs(regions) do
    r.lines = vim.list_slice(lines, r.start, r.stop)
    r.stop = nil
  end
  return regions
end

return M
