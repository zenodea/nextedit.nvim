-- Finds sites the user's recent edits probably affect next: places where
-- identifiers the edits removed or replaced (an old function name, say)
-- still occur. Candidates come from two sources, most precise first:
--
--   1. Diagnostics, in any loaded buffer, whose message or line mentions a
--      removed identifier. A rename leaves "undefined name" errors at every
--      stale call site, which is as exact as this signal gets. (LSP
--      references cannot find these: stale sites are *broken* references.)
--   2. A plain text scan for the removed identifiers, in the current buffer
--      outside the excerpt and then in other loaded buffers.
--
-- The resulting regions are sent as extra editable context, so a prediction
-- can land far from the cursor or in another file; the UI offers tab-to-jump.
local M = {}

local max_regions = 4
local MAX_BUFFERS = 8
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

local function contains_any(text, tokens)
  for _, token in ipairs(tokens) do
    if text:find(token, 1, true) then
      return true
    end
  end
  return false
end

--- Overrides from setup(); only the region cap is tunable so far.
function M.configure(o)
  max_regions = o.max_regions or max_regions
end

--- Up to max_regions excerpts ({ bufnr, path, start, lines }) around lines
--- that still contain an identifier the recent edits removed. Looks in the
--- origin buffer outside [first, last] and in other loaded buffers that pass
--- `allowed` (the caller's own enablement rules, so denied files stay out).
function M.find(buf, edits, first, last, allowed)
  local tokens = stale_tokens(edits)
  if #tokens == 0 then
    return {}
  end

  local order, hits = {}, {} -- bufnr -> { lnum, ... }, insertion-ordered
  local function add(bufnr, lnum)
    if not hits[bufnr] then
      hits[bufnr] = {}
      order[#order + 1] = bufnr
    end
    table.insert(hits[bufnr], lnum)
  end

  -- Diagnostics anywhere, most precise first.
  for _, d in ipairs(vim.diagnostic.get(nil)) do
    if
      d.severity <= vim.diagnostic.severity.WARN
      and vim.api.nvim_buf_is_loaded(d.bufnr)
      and (d.bufnr == buf or (allowed == nil or allowed(d.bufnr)))
      and not (d.bufnr == buf and d.lnum + 1 >= first and d.lnum + 1 <= last)
    then
      local line = vim.api.nvim_buf_get_lines(d.bufnr, d.lnum, d.lnum + 1, false)[1] or ""
      if contains_any(d.message, tokens) or contains_any(line, tokens) then
        add(d.bufnr, d.lnum + 1)
      end
    end
  end

  -- Text scan: origin buffer, then other loaded buffers.
  local scan = { buf }
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if #scan >= MAX_BUFFERS then
      break
    end
    if
      b ~= buf
      and vim.api.nvim_buf_is_loaded(b)
      and vim.bo[b].buflisted
      and vim.api.nvim_buf_get_name(b) ~= "" -- an unnamed buffer has no path to send
      and (allowed == nil or allowed(b))
    then
      scan[#scan + 1] = b
    end
  end
  for _, b in ipairs(scan) do
    for lnum, line in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
      if not (b == buf and lnum >= first and lnum <= last) and contains_any(line, tokens) then
        add(b, lnum)
      end
    end
  end

  -- Merge each buffer's hits into context regions, capped overall.
  local regions = {}
  for _, bufnr in ipairs(order) do
    if #regions >= max_regions then
      break
    end
    local lnums = hits[bufnr]
    table.sort(lnums)
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":.")
    local prev = nil
    for _, lnum in ipairs(lnums) do
      local s, e = math.max(1, lnum - CONTEXT), math.min(line_count, lnum + CONTEXT)
      if prev and prev.bufnr == bufnr and s <= prev.stop + 1 then
        prev.stop = math.max(prev.stop, e)
      elseif #regions < max_regions then
        prev = { bufnr = bufnr, path = path, start = s, stop = e }
        regions[#regions + 1] = prev
      end
    end
  end
  for _, r in ipairs(regions) do
    r.lines = vim.api.nvim_buf_get_lines(r.bufnr, r.start - 1, r.stop, false)
    r.stop = nil
  end
  return regions
end

return M
