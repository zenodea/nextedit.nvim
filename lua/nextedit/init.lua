local diff = require("nextedit.diff")
local nes = require("nextedit.nes")
local outline = require("nextedit.outline")
local regions = require("nextedit.regions")
local server = require("nextedit.server")
local track = require("nextedit.track")
local ui = require("nextedit.ui")

local M = {}

-- Providers fast enough (and trained) to predict mid-typing; chat providers
-- reason better about a completed edit than a half-typed identifier.
local TYPING_PROVIDERS = { mercury = true, ollama = true, zeta = true, zeta2 = true }

local defaults = {
  trigger = nil, -- "boundary" | "typing"; defaults to "typing" for mercury/ollama/zeta, "boundary" otherwise
  triggers = { -- what requests a prediction, besides edits themselves
    movement = true, -- cursor movement
    idle = true, -- idling for 'updatetime' (CursorHold)
    diagnostics = true, -- newly published LSP diagnostics
    signal_required = true, -- movement/idle only ask when there are recent edits or diagnostics to reason from
  },
  multiline = true, -- false shows only single-line predictions
  debounce_ms = 150,
  context_lines = 40, -- buffer context sent above and below the cursor
  max_diagnostics = 8, -- diagnostics sent alongside the excerpt
  diagnostics_severity = "warn", -- least severe diagnostic level still sent: "error", "warn", "info" or "hint"
  outline = true, -- send a treesitter outline of the whole file
  cross_file = true, -- let predictions target other open buffers
  max_regions = 4, -- related regions sent as extra editable context
  accept_key = "<Tab>",
  dismiss_key = "<C-]>",
  jump_distance = 5, -- accepts farther than this from the cursor jump first, then apply
  sign_text = "»", -- gutter sign marking a pending prediction; "" disables it
  server_cmd = nil, -- defaults to the bundled Rust binary
  filetypes = { gitcommit = false, gitrebase = false, help = false }, -- per-filetype toggle; unlisted filetypes are enabled
  deny_paths = { "%.env", "%.pem$", "secret", "credential" }, -- never predict in files matching these Lua patterns
  max_lines = 10000, -- skip buffers larger than this (whole-buffer snapshots get expensive)
  provider = nil, -- "anthropic" (default), "copilot", "copilot-nes", "openai", "mercury", "gemini", "xai", "mistral", "openrouter", "ollama" or "zeta"
  model = nil, -- provider-specific model name
  api_url = nil, -- override the provider's endpoint, e.g. a local llama.cpp server
  api_key = nil, -- prefer the provider's env var; set this only for keyless local setups
}

local opts
local timer = vim.uv.new_timer()
local inflight = nil -- { buf, sent_at }
local rerequest = false -- a request came in while one was in flight
local last_fingerprint = nil -- context of the last dispatched request
local INFLIGHT_TIMEOUT_MS = 10000
local last_error = nil
local error_notified = false

--- Warn once per failure streak: with typing-triggered providers an outage
--- would otherwise notify on every pause.
local function report_error(err)
  last_error = err
  if not error_notified then
    error_notified = true
    vim.notify("nextedit: " .. err .. " (muting further errors until a request succeeds)", vim.log.levels.WARN)
  end
end

local function report_ok()
  last_error = nil
  error_notified = false
end

local function plugin_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(source, ":h:h:h")
end

local function server_env()
  return {
    NEXTEDIT_PROVIDER = opts.provider,
    NEXTEDIT_MODEL = opts.model,
    NEXTEDIT_API_URL = opts.api_url,
    NEXTEDIT_API_KEY = opts.api_key,
  }
end

local function default_server_cmd()
  local target = plugin_root() .. "/server/target/"
  for _, profile in ipairs({ "release", "debug" }) do
    local bin = target .. profile .. "/nextedit-server"
    if vim.fn.executable(bin) == 1 then
      return { bin }
    end
  end
  return { target .. "release/nextedit-server" } -- let server.start report the error
end

--- The lines [s, e] as they were sent to the model, from whichever region of
--- the file `path` contains the whole range.
local function sent_lines(params, path, s, e)
  local function slice(start, lines)
    if s >= start and e <= start + #lines - 1 then
      local out = {}
      for i = s, e do
        out[#out + 1] = lines[i - start + 1]
      end
      return out
    end
  end
  local got = path == params.path and slice(params.excerpt_start, params.excerpt_lines) or nil
  for _, r in ipairs(params.extra_regions or {}) do
    if r.path == path then
      got = got or slice(r.start, r.lines)
    end
  end
  return got
end

--- The prediction targeted the buffers as they were when the request was
--- sent; shift it across the edits made since, and show it only if the lines
--- it replaces are still exactly what the model saw.
local function remap_and_show(buf, params, targets, result)
  local events = track.finish(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_get_current_buf() ~= buf then
    return
  end
  local path = result.path or params.path
  if path ~= params.path then
    -- Cross-file edit. Only the origin buffer's changes are tracked, so no
    -- remapping: the target lines must be exactly what the model saw.
    local target = targets[path]
    if not target or not vim.api.nvim_buf_is_valid(target) or not vim.api.nvim_buf_is_loaded(target) then
      return
    end
    local original = sent_lines(params, path, result.start_line, result.end_line)
    local lines = vim.api.nvim_buf_get_lines(target, result.start_line - 1, result.end_line, false)
    if not original or not vim.deep_equal(lines, original) then
      return
    end
    ui.show(target, {
      start_line = result.start_line,
      end_line = result.end_line,
      replacement = result.replacement,
      hint_buf = buf, -- show "edit elsewhere" at the cursor
    }, vim.b[target].changedtick)
    return
  end
  local start_line, end_line = track.remap(result.start_line, result.end_line, events)
  if not start_line then
    return
  end
  local original = sent_lines(params, path, result.start_line, result.end_line)
  if not original then
    return
  end
  local current = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
  if not vim.deep_equal(current, original) then
    return
  end
  ui.show(buf, {
    start_line = start_line,
    end_line = end_line,
    replacement = result.replacement,
  }, vim.b[buf].changedtick)
end

--- Whether predictions should run in this buffer at all: real file buffers
--- only, minus disabled filetypes, denied paths (secrets should never reach
--- an API) and oversized files.
local function enabled(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
    return false
  end
  if opts.filetypes[vim.bo[buf].filetype] == false then
    return false
  end
  if vim.api.nvim_buf_line_count(buf) > opts.max_lines then
    return false
  end
  local path = vim.api.nvim_buf_get_name(buf):lower()
  for _, pat in ipairs(opts.deny_paths) do
    if path:find(pat) then
      return false
    end
  end
  return true
end

--- Error and warning diagnostics inside the excerpt, formatted for the
--- prompt. An LSP error where the user just edited is the strongest "next
--- edit" signal there is.
local function excerpt_diagnostics(buf, first, last)
  local out = {}
  local floor = vim.diagnostic.severity[opts.diagnostics_severity:upper()] or vim.diagnostic.severity.WARN
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    local lnum = d.lnum + 1
    if lnum >= first and lnum <= last and d.severity <= floor then
      local severity = vim.diagnostic.severity[d.severity] or "?"
      out[#out + 1] = ("line %d [%s]: %s"):format(lnum, severity, d.message:gsub("%s+", " "))
      if #out >= opts.max_diagnostics then
        break
      end
    end
  end
  return out
end

--- With multiline off, a prediction must keep to one line: a single line
--- replaced by at most a single line.
local function fits_multiline(result)
  return opts.multiline or (result.end_line == result.start_line and #result.replacement <= 1)
end

--- kind: nil for edit-triggered requests, "movement" for cursor-move, idle
--- and diagnostics-change ones (which need existing signal and never replace
--- a visible prediction), "manual" for :NextEdit (which skips the
--- duplicate-context check).
local function request_prediction(kind)
  local buf = vim.api.nvim_get_current_buf()
  if not enabled(buf) then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_line = cursor[1]
  local first = math.max(1, cursor_line - opts.context_lines)
  local last = math.min(vim.api.nvim_buf_line_count(buf), cursor_line + opts.context_lines)
  local recent_edits = diff.take(buf)
  local diagnostics = excerpt_diagnostics(buf, first, last)
  -- Movement gives the model nothing new by itself: only ask when there is
  -- recent-edit or diagnostic signal to reason from (unless the user turned
  -- signal_required off), and never while a prediction is already on screen.
  if
    kind == "movement"
    and (ui.visible() or (opts.triggers.signal_required and #recent_edits == 0 and #diagnostics == 0))
  then
    return
  end
  -- One request at a time: let the in-flight one finish (its response can be
  -- remapped) and go again right after, instead of wasting the round trip.
  if inflight then
    if vim.uv.now() - inflight.sent_at < INFLIGHT_TIMEOUT_MS then
      rerequest = true
      return
    end
    inflight = nil -- response never came; assume the server lost it
  end
  -- copilot-nes speaks LSP to the Copilot server directly; the sidecar and
  -- the excerpt/remap machinery are not involved (responses are tied to a
  -- document version, so stale ones are dropped rather than remapped).
  if opts.provider == "copilot-nes" then
    local fingerprint = ("nes:%d:%d:%d"):format(buf, cursor_line, vim.b[buf].changedtick)
    if kind ~= "manual" and fingerprint == last_fingerprint then
      return
    end
    local sent = nes.request(buf, function(result, err)
      inflight = nil
      if err then
        report_error(err)
      elseif result and fits_multiline(result) and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_get_current_buf() == buf then
        report_ok()
        ui.show(buf, result, vim.b[buf].changedtick)
      else
        report_ok()
      end
      if rerequest then
        rerequest = false
        request_prediction()
      end
    end)
    if sent then
      inflight = { buf = buf, sent_at = vim.uv.now() }
      last_fingerprint = fingerprint
    end
    return
  end
  local params = {
    path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":."),
    filetype = vim.bo[buf].filetype,
    cursor_line = cursor_line,
    cursor_col = cursor[2],
    excerpt_start = first,
    excerpt_lines = vim.api.nvim_buf_get_lines(buf, first - 1, last, false),
    recent_edits = recent_edits,
    diagnostics = diagnostics,
    outline = opts.outline and outline.get(buf) or nil,
  }
  -- Candidate sites the recent edits point at, in this file or another open
  -- buffer; lets the prediction land far from the cursor, with tab-to-jump.
  -- With cross_file off, other buffers are excluded from the search.
  local allow = enabled
  if not opts.cross_file then
    allow = function(b)
      return b == buf and enabled(b)
    end
  end
  local found = regions.find(buf, params.recent_edits, first, last, allow)
  local targets = {} -- path -> bufnr, for routing a cross-file prediction
  params.extra_regions = {}
  for _, r in ipairs(found) do
    targets[r.path] = r.bufnr
    params.extra_regions[#params.extra_regions + 1] = { path = r.path, start = r.start, lines = r.lines }
  end
  -- Identical context produces an identical prediction: skip the round trip.
  -- The cursor column is left out so wandering along a line never refires.
  local fingerprint = table.concat({
    params.path,
    tostring(cursor_line),
    table.concat(params.excerpt_lines, "\n"),
    vim.json.encode(params.recent_edits),
    table.concat(params.diagnostics, "\n"),
    vim.json.encode(params.extra_regions),
  }, "\0")
  if kind ~= "manual" and fingerprint == last_fingerprint then
    return
  end
  track.begin(buf)
  local id = server.predict(params, function(result, err)
    vim.schedule(function()
      inflight = nil
      if err then
        track.finish(buf)
        report_error(err)
      elseif result and result.has_edit and fits_multiline(result) then
        report_ok()
        remap_and_show(buf, params, targets, result)
      else
        track.finish(buf)
        report_ok()
      end
      if rerequest then
        rerequest = false
        request_prediction()
      end
    end)
  end)
  if id then
    inflight = { buf = buf, sent_at = vim.uv.now() }
    last_fingerprint = fingerprint
  else
    track.finish(buf)
  end
end

local function schedule_prediction(kind)
  timer:stop()
  timer:start(opts.debounce_ms, 0, vim.schedule_wrap(function()
    request_prediction(kind)
  end))
end

--- Introspection for :checkhealth; nil until setup() has run.
function M.current_opts()
  return opts
end

--- For statuslines: provider name, whether a request is in flight, and the
--- last error (nil when healthy).
function M.status()
  return {
    provider = (opts and opts.provider) or vim.env.NEXTEDIT_PROVIDER or "anthropic",
    inflight = inflight ~= nil,
    last_error = last_error,
  }
end

function M.server_command()
  return (opts and opts.server_cmd) or default_server_cmd()
end

function M.setup(user_opts)
  opts = vim.tbl_deep_extend("force", defaults, user_opts or {})
  -- A user deny_paths list replaces the default outright; index-wise deep
  -- merging of lists produces nonsense.
  if user_opts and user_opts.deny_paths then
    opts.deny_paths = user_opts.deny_paths
  end

  regions.configure({ max_regions = opts.max_regions })
  ui.configure({ jump_distance = opts.jump_distance, sign_text = opts.sign_text })

  vim.api.nvim_set_hl(0, "NextEditOld", { default = true, link = "DiffDelete" })
  vim.api.nvim_set_hl(0, "NextEditNew", { default = true, link = "DiffAdd" })
  vim.api.nvim_set_hl(0, "NextEditSign", { default = true, link = "DiagnosticSignInfo" })

  -- copilot-nes runs over the Copilot LSP client; no sidecar to start.
  if opts.provider ~= "copilot-nes" and not server.start(opts.server_cmd or default_server_cmd(), server_env()) then
    return
  end

  local group = vim.api.nvim_create_augroup("nextedit", { clear = true })
  if opts.provider == "copilot-nes" then
    vim.api.nvim_create_autocmd("BufEnter", {
      group = group,
      callback = function(ev)
        nes.attach(ev.buf)
      end,
    })
    vim.api.nvim_create_autocmd("LspAttach", {
      group = group,
      callback = function(ev)
        nes.did_focus(ev.buf)
      end,
    })
    nes.attach(vim.api.nvim_get_current_buf())
    vim.api.nvim_create_user_command("NextEditSignIn", nes.sign_in, { desc = "Sign in to GitHub Copilot" })
  end
  -- Predictions are requested at edit boundaries — leaving insert mode or a
  -- normal-mode buffer change — never mid-keystroke, so the model always sees
  -- a completed edit instead of a half-typed identifier.
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = group,
    pattern = "i*:n",
    callback = function(ev)
      if enabled(ev.buf) then
        diff.commit(ev.buf)
        schedule_prediction()
      end
    end,
  })
  vim.api.nvim_create_autocmd("TextChanged", {
    group = group,
    callback = function(ev)
      ui.check_undo(ev.buf) -- undoing an accepted prediction rejects it
      ui.dismiss()
      if enabled(ev.buf) then
        diff.commit(ev.buf)
        schedule_prediction()
      end
    end,
  })
  local provider = opts.provider or vim.env.NEXTEDIT_PROVIDER or "anthropic"
  local trigger = opts.trigger or (TYPING_PROVIDERS[provider] and "typing" or "boundary")
  if trigger == "typing" then
    -- Also predict while typing: fast edit-prediction models handle
    -- half-finished lines well, and the round trip is cheap enough.
    vim.api.nvim_create_autocmd("TextChangedI", {
      group = group,
      callback = function()
        ui.dismiss()
        schedule_prediction()
      end,
    })
    vim.api.nvim_create_autocmd("InsertEnter", { group = group, callback = ui.dismiss })
    -- While a completion menu is open the preview renders above the change;
    -- when the menu closes without a text change, move it back below.
    -- (Accepting a completion fires TextChangedI, which re-requests anyway.)
    vim.api.nvim_create_autocmd("CompleteDone", { group = group, callback = ui.refresh })
  else
    vim.api.nvim_create_autocmd({ "TextChangedI", "InsertEnter" }, {
      group = group,
      callback = function()
        timer:stop()
        ui.dismiss()
      end,
    })
  end
  -- Movement and idle also trigger, so suggestions appear where you look,
  -- not only where you type. request_prediction gates these on existing
  -- signal, and the fingerprint check keeps repeat contexts free. Each
  -- trigger has its own switch in opts.triggers.
  local move_events = {}
  if opts.triggers.movement then
    move_events[#move_events + 1] = "CursorMoved"
  end
  if opts.triggers.idle then
    move_events[#move_events + 1] = "CursorHold"
  end
  if #move_events > 0 then
    vim.api.nvim_create_autocmd(move_events, {
      group = group,
      callback = function(ev)
        if enabled(ev.buf) and not ui.visible() then
          schedule_prediction("movement")
        end
      end,
    })
  end
  -- LSP diagnostics land asynchronously, usually after the edit-triggered
  -- request already went out without them; ask again once they arrive so
  -- the model sees the errors and can propose the fix. The fingerprint
  -- includes diagnostics, so a publish that changed nothing costs no
  -- round trip.
  if opts.triggers.diagnostics then
    vim.api.nvim_create_autocmd("DiagnosticChanged", {
      group = group,
      callback = function(ev)
        if
          ev.buf == vim.api.nvim_get_current_buf()
          and enabled(ev.buf)
          and not ui.visible()
          and vim.api.nvim_get_mode().mode:find("^n")
        then
          schedule_prediction("movement")
        end
      end,
    })
  end
  local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
  vim.on_key(function(_, typed)
    if typed == esc and ui.visible() and vim.api.nvim_get_mode().mode == "n" then
      vim.schedule(ui.reject)
    end
  end, vim.api.nvim_create_namespace("nextedit.esc"))
  vim.api.nvim_create_autocmd("BufLeave", {
    group = group,
    callback = function(ev)
      -- Dismiss only when leaving the buffer holding the prediction:
      -- accepting a cross-buffer prediction jumps *into* that buffer, and
      -- the overlay must survive the switch.
      if ui.buffer() == ev.buf then
        ui.dismiss()
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    callback = function(ev)
      diff.forget(ev.buf)
      track.forget(ev.buf)
    end,
  })

  -- In boundary mode predictions are cleared on InsertEnter, so an
  -- insert-mode mapping would never fire and would shadow completion/snippet
  -- <Tab> mappings for nothing; in typing mode predictions appear while
  -- typing, so accept/dismiss must work there too.
  local modes = trigger == "typing" and { "i", "n" } or "n"
  vim.keymap.set(modes, opts.accept_key, function()
    if not ui.accept() then
      -- No prediction pending: pass the key through with its default behavior.
      local key = vim.api.nvim_replace_termcodes(opts.accept_key, true, false, true)
      vim.api.nvim_feedkeys(key, "n", false)
    end
  end, { desc = "nextedit: accept prediction" })
  vim.keymap.set(modes, opts.dismiss_key, ui.reject, { desc = "nextedit: dismiss prediction" })

  vim.api.nvim_create_user_command("NextEdit", function()
    request_prediction("manual")
  end, { desc = "Request a prediction now" })
  vim.api.nvim_create_user_command("NextEditRestart", function()
    if opts.provider == "copilot-nes" then
      vim.notify("nextedit: copilot-nes uses the Copilot LSP client; restart that instead (:LspRestart)", vim.log.levels.INFO)
      return
    end
    server.stop()
    server.start(opts.server_cmd or default_server_cmd(), server_env())
  end, { desc = "Restart the nextedit server" })
end

return M
