-- Headless test for prediction remapping: nvim -l tests/run.lua
-- The fake server always predicts a replacement of line 4 (as numbered at
-- request time) after a 400ms delay, leaving a window to edit the buffer.

local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))
vim.opt.rtp:prepend(root)

local ui = require("nextedit.ui")
local track = require("nextedit.track")

local failures = 0
local function check(name, got, want)
  if vim.deep_equal(got, want) then
    print("ok   " .. name)
  else
    failures = failures + 1
    print(("FAIL %s\n  got:  %s\n  want: %s"):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

-- remap() unit cases: events are 0-indexed {first, last, new_last}.
check("remap: no events", { track.remap(4, 5, {}) }, { 4, 5 })
check("remap: insert 2 lines above", { track.remap(4, 5, { { first = 0, last = 0, new_last = 2 } }) }, { 6, 7 })
check("remap: delete a line above", { track.remap(4, 5, { { first = 0, last = 1, new_last = 0 } }) }, { 3, 4 })
check("remap: edit below is ignored", { track.remap(4, 5, { { first = 5, last = 6, new_last = 6 } }) }, { 4, 5 })
check("remap: edit inside drops it", { track.remap(4, 5, { { first = 3, last = 4, new_last = 4 } }) }, {})
check("remap: insert at region end is below", { track.remap(4, 5, { { first = 5, last = 5, new_last = 6 } }) }, { 4, 5 })

-- Edit-history coalescing: nearby commits merge, distant ones start entries.
local diffmod = require("nextedit.diff")
local dbuf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(dbuf, 0, -1, false, {
  "one", "two", "three", "four", "five", "six",
  "seven", "eight", "nine", "ten", "eleven", "twelve",
})
check("history: starts empty", diffmod.take(dbuf), {})
vim.api.nvim_buf_set_lines(dbuf, 0, 1, false, { "ONE" })
check("history: uncommitted edit is pending", #diffmod.take(dbuf), 1)
diffmod.commit(dbuf)
vim.api.nvim_buf_set_lines(dbuf, 1, 2, false, { "TWO" })
diffmod.commit(dbuf)
check("history: nearby commits merge into one entry", #diffmod.take(dbuf), 1)
check("history: merged entry spans both changes", diffmod.take(dbuf)[1]:match("ONE") ~= nil
  and diffmod.take(dbuf)[1]:match("TWO") ~= nil, true)
vim.api.nvim_buf_set_lines(dbuf, 11, 12, false, { "TWELVE" })
diffmod.commit(dbuf)
check("history: distant commit starts a new entry", #diffmod.take(dbuf), 2)
diffmod.forget(dbuf)

local SAMPLE = {
  "def add(a: int, b: int) -> int:",
  "    return a + b",
  "",
  "def sub(a, b):",
  "    return a - b",
}

require("nextedit").setup({
  server_cmd = { root .. "/tests/fake-server.py" },
  debounce_ms = 3600000, -- only :NextEdit-triggered requests during tests
})

local function reset_buffer()
  ui.dismiss()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, SAMPLE)
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
end

local function predict_and_wait()
  vim.cmd.NextEdit()
  return vim.wait(3000, ui.visible, 10)
end

-- 1. Untouched buffer: prediction shows and accepts at line 4.
reset_buffer()
check("show: prediction arrives", predict_and_wait(), true)
check("accept: applies the edit", ui.accept(), true)
check("accept: line 4 replaced", vim.api.nvim_buf_get_lines(0, 3, 4, false), { "def sub(a: int, b: int) -> int:" })

-- 2. Two lines inserted above mid-flight: prediction lands shifted to line 6.
reset_buffer()
vim.cmd.NextEdit()
vim.wait(100)
vim.api.nvim_buf_set_lines(0, 0, 0, false, { "import math", "" })
check("remap live: prediction survives the insert", vim.wait(3000, ui.visible, 10), true)
check("remap live: accept lands at the shifted line", ui.accept(), true)
check("remap live: line 6 replaced", vim.api.nvim_buf_get_lines(0, 5, 6, false), { "def sub(a: int, b: int) -> int:" })

-- 3. The predicted line itself edited mid-flight: prediction is dropped.
reset_buffer()
vim.cmd.NextEdit()
vim.wait(100)
vim.api.nvim_buf_set_lines(0, 3, 4, false, { "def sub(x, y):" })
check("overlap live: prediction is dropped", vim.wait(1500, ui.visible, 10), false)

if failures > 0 then
  print(failures .. " failure(s)")
  vim.cmd.cquit()
end
print("all tests passed")
vim.cmd("quitall!")
