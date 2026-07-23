local diff = require("nextedit.diff")
local server = require("nextedit.server")
local ui = require("nextedit.ui")

local M = {}

local defaults = {
  debounce_ms = 300,
  context_lines = 40, -- buffer context sent above and below the cursor
  accept_key = "<Tab>",
  dismiss_key = "<C-]>",
  server_cmd = nil, -- defaults to the bundled Rust binary
  provider = nil, -- "anthropic" (default), "openai", "mercury", "ollama" or "zeta"
  model = nil, -- provider-specific model name
  api_url = nil, -- override the provider's endpoint, e.g. a local llama.cpp server
  api_key = nil, -- prefer the provider's env var; set this only for keyless local setups
}

local opts
local timer = vim.uv.new_timer()
local latest_id = 0

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

local function request_prediction()
  local buf = vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
    return
  end
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local first = math.max(1, cursor_line - opts.context_lines)
  local last = math.min(vim.api.nvim_buf_line_count(buf), cursor_line + opts.context_lines)
  local tick = vim.b[buf].changedtick
  local id
  id = server.predict({
    path = vim.api.nvim_buf_get_name(buf),
    filetype = vim.bo[buf].filetype,
    cursor_line = cursor_line,
    excerpt_start = first,
    excerpt_lines = vim.api.nvim_buf_get_lines(buf, first - 1, last, false),
    recent_edits = diff.take(buf),
  }, function(result, err)
    vim.schedule(function()
      if err then
        vim.notify("nextedit: " .. err, vim.log.levels.WARN)
        return
      end
      -- Drop stale responses: superseded by a newer request, or the buffer moved on.
      if id ~= latest_id or not vim.api.nvim_buf_is_valid(buf) or vim.b[buf].changedtick ~= tick then
        return
      end
      if result and result.has_edit then
        ui.show(buf, result, tick)
      end
    end)
  end)
  if id then
    latest_id = id
  end
end

local function schedule_prediction()
  timer:stop()
  timer:start(opts.debounce_ms, 0, vim.schedule_wrap(request_prediction))
end

function M.setup(user_opts)
  opts = vim.tbl_deep_extend("force", defaults, user_opts or {})

  vim.api.nvim_set_hl(0, "NextEditOld", { default = true, link = "DiffDelete" })
  vim.api.nvim_set_hl(0, "NextEditNew", { default = true, link = "DiffAdd" })

  if not server.start(opts.server_cmd or default_server_cmd(), server_env()) then
    return
  end

  local group = vim.api.nvim_create_augroup("nextedit", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    group = group,
    callback = function()
      ui.dismiss()
      schedule_prediction()
    end,
  })
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
    end,
  })

  vim.keymap.set({ "i", "n" }, opts.accept_key, function()
    if not ui.accept() then
      -- No prediction pending: pass the key through with its default behavior.
      local key = vim.api.nvim_replace_termcodes(opts.accept_key, true, false, true)
      vim.api.nvim_feedkeys(key, "n", false)
    end
  end, { desc = "nextedit: accept prediction" })
  vim.keymap.set({ "i", "n" }, opts.dismiss_key, ui.dismiss, { desc = "nextedit: dismiss prediction" })

  vim.api.nvim_create_user_command("NextEdit", request_prediction, { desc = "Request a prediction now" })
  vim.api.nvim_create_user_command("NextEditRestart", function()
    server.stop()
    server.start(opts.server_cmd or default_server_cmd(), server_env())
  end, { desc = "Restart the nextedit server" })
end

return M
