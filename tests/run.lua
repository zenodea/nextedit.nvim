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
check("history: merged entry spans both changes", diffmod.take(dbuf)[1].diff:match("ONE") ~= nil
  and diffmod.take(dbuf)[1].diff:match("TWO") ~= nil, true)
vim.api.nvim_buf_set_lines(dbuf, 11, 12, false, { "TWELVE" })
diffmod.commit(dbuf)
check("history: distant commit starts a new entry", #diffmod.take(dbuf), 2)
diffmod.forget(dbuf)

-- Outline: definition nodes from treesitter, numbered with absolute lines.
local outline = require("nextedit.outline")
local obuf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(obuf, 0, -1, false, {
  "local function foo()", "end", "", "local function bar()", "end",
})
vim.bo[obuf].filetype = "lua"
local o = outline.get(obuf)
check("outline: finds both functions", #o, 2)
check("outline: entries carry absolute line numbers",
  o[2]:match("^%s*4|") ~= nil and o[2]:match("bar") ~= nil, true)

-- Regions: occurrences of identifiers the recent edits removed become extra
-- editable regions outside the excerpt.
local regionsmod = require("nextedit.regions")
local rbuf = vim.api.nvim_create_buf(false, true)
local rlines = { "def fetch_user(id):", "    return db.lookup(id)" }
for _ = 1, 10 do
  rlines[#rlines + 1] = ""
end
rlines[#rlines + 1] = "user = get_user(7)"
vim.api.nvim_buf_set_lines(rbuf, 0, -1, false, rlines)
local redit = { { path = "f.py", diff = "@@ -1,1 +1,1 @@\n-def get_user(id):\n+def fetch_user(id):" } }
local found = regionsmod.find(rbuf, redit, 1, 4)
check("regions: finds the stale call site", #found, 1)
local xbuf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(xbuf, "xtest.py")
vim.api.nvim_buf_set_lines(xbuf, 0, -1, false, { "print(get_user(2))" })
local found2 = regionsmod.find(rbuf, redit, 1, 4)
check("regions: finds sites in other listed buffers", #found2, 2)
check("regions: cross-buffer region carries its own path and bufnr",
  found2[2].path:match("xtest%.py$") ~= nil and found2[2].bufnr == xbuf, true)
vim.api.nvim_buf_delete(xbuf, { force = true })
check("regions: region covers the occurrence", found[1].start <= 13
  and found[1].start + #found[1].lines - 1 >= 13, true)
check("regions: nothing without stale tokens",
  #regionsmod.find(rbuf, { { path = "f.py", diff = "@@ -1 +1 @@\n-x\n+y" } }, 1, 4), 0)

-- Rendering: small word changes are inline, rewrites fall back to block style.
local render = require("nextedit.render")
local inline = render.extmarks({ "local foo = 1" }, { "local bar = 1" }, 10)
check("render: word change makes two inline marks", #inline, 2)
check("render: deletion span covers the old word",
  { inline[1][1], inline[1][2], inline[1][3].end_col }, { 10, 6, 9 })
check("render: insertion is inline virtual text", inline[2][3].virt_text[1][1], "bar")
local block = render.extmarks({ "x" }, { "something totally different" }, 0)
check("render: rewrite falls back to line highlight", block[1][3].line_hl_group, "NextEditOld")
check("render: rewrite shows the new line below", block[2][3].virt_lines[1][1][1], "something totally different")
local grow = render.extmarks({ "a", "b" }, { "a", "b", "c" }, 0)
check("render: pure insertion renders as virtual lines", grow[1][3].virt_lines[1][1][1], "c")
local flipped = render.extmarks({ "x" }, { "something totally different" }, 3, true)
check("render: above-placement anchors the preview over the change",
  { flipped[2][1], flipped[2][3].virt_lines_above }, { 3, true })

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

-- 4. Rejected suggestions stay rejected until the underlying lines change.
reset_buffer()
local pred = { start_line = 4, end_line = 4, replacement = { "def sub(x):" } }
ui.show(0, pred, vim.b[0].changedtick)
check("reject: suggestion shows", ui.visible(), true)
ui.reject()
ui.show(0, pred, vim.b[0].changedtick)
check("reject: identical suggestion is suppressed", ui.visible(), false)
vim.api.nvim_buf_set_lines(0, 3, 4, false, { "def sub(a, b, c):" })
ui.show(0, pred, vim.b[0].changedtick)
check("reject: shows again once the line changed", ui.visible(), true)
ui.dismiss()

-- 5. Cursor far from the prediction: first accept jumps, second applies.
reset_buffer()
vim.api.nvim_buf_set_lines(0, 5, 5, false, { "", "# 7", "# 8", "# 9", "# 10", "# 11", "# 12" })
vim.api.nvim_win_set_cursor(0, { 12, 0 })
check("jump: prediction arrives", predict_and_wait(), true)
check("jump: first accept jumps instead of applying", ui.accept(), true)
check("jump: cursor lands on the edit", vim.api.nvim_win_get_cursor(0)[1], 4)
check("jump: second accept applies", ui.accept(), true)
check("jump: line 4 replaced", vim.api.nvim_buf_get_lines(0, 3, 4, false), { "def sub(a: int, b: int) -> int:" })

-- 6. Cross-buffer prediction: first accept switches buffer, second applies.
reset_buffer()
local origin = vim.api.nvim_get_current_buf()
local other = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(other, 0, -1, false, { "alpha", "beta", "gamma" })
ui.show(other, { start_line = 2, end_line = 2, replacement = { "BETA" }, hint_buf = origin },
  vim.b[other].changedtick)
check("crossbuf: prediction visible", ui.visible(), true)
check("crossbuf: first accept switches to the buffer", ui.accept(), true)
check("crossbuf: prediction survives the switch", ui.visible(), true)
check("crossbuf: current buffer is the target", vim.api.nvim_get_current_buf(), other)
check("crossbuf: second accept applies", ui.accept(), true)
check("crossbuf: line replaced", vim.api.nvim_buf_get_lines(other, 1, 2, false), { "BETA" })

if failures > 0 then
  print(failures .. " failure(s)")
  vim.cmd.cquit()
end
print("all tests passed")
vim.cmd("quitall!")
