-- Records buffer changes made while a prediction request is in flight, so a
-- late response can be shifted to its new position instead of thrown away.
local M = {}

local state = {} -- buf -> { recording = boolean, events = { {first, last, new_last}, ... } }

local function ensure_attached(buf)
  if state[buf] then
    return
  end
  state[buf] = { recording = false, events = {} }
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function(_, b, _, first, last, new_last)
      local s = state[b]
      if not s then
        return true -- detach
      end
      if s.recording then
        table.insert(s.events, { first = first, last = last, new_last = new_last })
      end
    end,
  })
end

--- Start recording changes to buf (called when a request is sent).
function M.begin(buf)
  ensure_attached(buf)
  state[buf].recording = true
  state[buf].events = {}
end

--- Stop recording and return the changes made since begin().
function M.finish(buf)
  local s = state[buf]
  if not s then
    return {}
  end
  s.recording = false
  local events = s.events
  s.events = {}
  return events
end

function M.forget(buf)
  state[buf] = nil
end

--- Shift the 1-indexed inclusive line range [start_line, end_line] across the
--- recorded events. Returns the remapped range, or nil if any event touched
--- lines inside the range.
function M.remap(start_line, end_line, events)
  local s, e = start_line - 1, end_line -- 0-indexed, end-exclusive
  for _, ev in ipairs(events) do
    if ev.last <= s then
      local delta = ev.new_last - ev.last
      s, e = s + delta, e + delta
    elseif ev.first < e then
      return nil
    end
  end
  return s + 1, e
end

return M
