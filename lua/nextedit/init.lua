local diff = require("nextedit.diff")
local nes = require("nextedit.nes")
local outline = require("nextedit.outline")
local server = require("nextedit.server")
local track = require("nextedit.track")
local ui = require("nextedit.ui")

local M = {}

-- Providers fast enough (and trained) to predict mid-typing; chat providers
-- reason better about a completed edit than a half-typed identifier.
local TYPING_PROVIDERS = { mercury = true, ollama = true, zeta = true, zeta2 = true }

local defaults = {
  trigger = nil, -- "boundary" | "typing"; defaults to "typing" for mercury/ollama/zeta, "boundary" otherwise
  debounce_ms = 150,
  context_lines = 40, -- buffer context sent above and below the cursor
  accept_key = "<Tab>",
  dismiss_key = "<C-]>",
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

--- The prediction targeted the excerpt as it was when the request was sent;
--- shift it across the edits made since, and show it only if the lines it
--- replaces are still exactly what the model saw.
local function remap_and_show(buf, params, result)
  local events = track.finish(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_get_current_buf() ~= buf then
    return
  end
  local start_line, end_line = track.remap(result.start_line, result.end_line, events)
  if not start_line then
    return
  end
  local original = {}
  for i = result.start_line, result.end_line do
    original[#original + 1] = params.excerpt_lines[i - params.excerpt_start + 1]
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
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    local lnum = d.lnum + 1
    if lnum >= first and lnum <= last and d.severity <= vim.diagnostic.severity.WARN then
      local severity = vim.diagnostic.severity[d.severity] or "?"
      out[#out + 1] = ("line %d [%s]: %s"):format(lnum, severity, d.message:gsub("%s+", " "))
      if #out >= 8 then
        break
      end
    end
  end
  return out
end

local function request_prediction()
  local buf = vim.api.nvim_get_current_buf()
  if not enabled(buf) then
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
    local sent = nes.request(buf, function(result, err)
      inflight = nil
      if err then
        report_error(err)
      elseif result and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_get_current_buf() == buf then
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
    end
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_line = cursor[1]
  local first = math.max(1, cursor_line - opts.context_lines)
  local last = math.min(vim.api.nvim_buf_line_count(buf), cursor_line + opts.context_lines)
  local params = {
    path = vim.api.nvim_buf_get_name(buf),
    filetype = vim.bo[buf].filetype,
    cursor_line = cursor_line,
    cursor_col = cursor[2],
    excerpt_start = first,
    excerpt_lines = vim.api.nvim_buf_get_lines(buf, first - 1, last, false),
    recent_edits = diff.take(buf),
    diagnostics = excerpt_diagnostics(buf, first, last),
    outline = outline.get(buf),
  }
  track.begin(buf)
  local id = server.predict(params, function(result, err)
    vim.schedule(function()
      inflight = nil
      if err then
        track.finish(buf)
        report_error(err)
      elseif result and result.has_edit then
        report_ok()
        remap_and_show(buf, params, result)
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
  else
    track.finish(buf)
  end
end

local function schedule_prediction()
  timer:stop()
  timer:start(opts.debounce_ms, 0, vim.schedule_wrap(request_prediction))
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
  local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
  vim.on_key(function(_, typed)
    if typed == esc and ui.visible() and vim.api.nvim_get_mode().mode == "n" then
      vim.schedule(ui.reject)
    end
  end, vim.api.nvim_create_namespace("nextedit.esc"))
  vim.api.nvim_create_autocmd("BufLeave", {
    group = group,
    callback = function()
      ui.dismiss()
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

  vim.api.nvim_create_user_command("NextEdit", request_prediction, { desc = "Request a prediction now" })
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
