-- Tracks what the user has been changing as a short history of unified diffs.
-- The baseline snapshot advances only at edit boundaries (commit() is called
-- when the user leaves insert mode or makes a normal-mode change), and
-- consecutive commits that touch the same region are merged into one entry.
-- The result is a history of *semantic* edits — "renamed this function",
-- "added this parameter" — rather than keystroke noise, which is what lets
-- the model predict a next edit instead of just completing text.
local M = {}

local MAX_EDITS = 6
local REGION_GAP = 5 -- commits further than this many lines apart start a new entry
local MERGE_WINDOW_MS = 10000 -- and so do commits after this long a pause

local state = {} -- buf -> { baseline, history = { {base, diff, region = {first, last}, at}, ... } }

local function buffer_text(buf)
	return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n"
end

local function ensure(buf)
	local s = state[buf]
	if not s then
		s = { baseline = buffer_text(buf), history = {} }
		state[buf] = s
	end
	return s
end

--- The changed line range in `after` coordinates, as {first, last}, or nil
--- when the texts are equal.
local function changed_region(before, after)
	local hunks = vim.diff(before, after, { result_type = "indices" })
	if not hunks or #hunks == 0 then
		return nil
	end
	local first, last = math.huge, 0
	for _, h in ipairs(hunks) do
		local start_b, count_b = h[3], h[4]
		first = math.min(first, start_b)
		last = math.max(last, start_b + math.max(count_b, 1) - 1)
	end
	return { first, last }
end

--- Record the edit made since the last commit, merging it into the previous
--- history entry when it continues the same edit (nearby and recent).
function M.commit(buf)
	local s = ensure(buf)
	local text = buffer_text(buf)
	if text == s.baseline then
		return
	end
	local now = vim.uv.now()
	local region = changed_region(s.baseline, text)
	local last = s.history[#s.history]
	-- `last.region` is in the coordinates of the text it produced, which is
	-- exactly `s.baseline`, so it is directly comparable to `region`.
	local continues = last
		and now - last.at < MERGE_WINDOW_MS
		and region[1] <= last.region[2] + REGION_GAP
		and region[2] >= last.region[1] - REGION_GAP
	if continues then
		last.diff = vim.diff(last.base, text, { ctxlen = 2 })
		last.region = changed_region(last.base, text) or region
		last.at = now
	else
		table.insert(s.history, {
			base = s.baseline,
			diff = vim.diff(s.baseline, text, { ctxlen = 2 }),
			region = region,
			at = now,
		})
		if #s.history > MAX_EDITS then
			table.remove(s.history, 1)
		end
	end
	s.baseline = text
end

--- The recent-edit history, oldest first, plus the uncommitted in-progress
--- edit (if any) as the final entry.
function M.take(buf)
	local s = ensure(buf)
	local edits = {}
	for _, entry in ipairs(s.history) do
		edits[#edits + 1] = entry.diff
	end
	local text = buffer_text(buf)
	if text ~= s.baseline then
		local pending = vim.diff(s.baseline, text, { ctxlen = 2 })
		if pending and pending ~= "" then
			edits[#edits + 1] = pending
		end
	end
	return edits
end

function M.forget(buf)
	state[buf] = nil
end

return M
