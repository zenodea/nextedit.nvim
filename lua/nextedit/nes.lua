-- Copilot's native Next Edit Suggestions, spoken directly to the
-- copilot-language-server LSP client attached to the buffer (by copilot.lua
-- with its LSP, or `vim.lsp.enable` on a native config). Unlike the other
-- providers this bypasses the Rust sidecar entirely: Neovim's LSP client
-- already keeps the document in sync, so we only issue GitHub's custom
-- textDocument/copilotInlineEdit request and translate the reply.
local M = {}

local inflight = nil -- { client_id, request_id }
local focused = {} -- client_id -> uri of the last didFocus notification

-- vim.lsp.Client functions are dot-called closures on 0.10 and real methods
-- on 0.11+; these helpers work on both.
local has_011 = vim.fn.has("nvim-0.11") == 1
local function lsp_request(client, method, params, handler, buf)
  if has_011 then
    return client:request(method, params, handler, buf)
  end
  return client.request(method, params, handler, buf)
end
local function lsp_notify(client, method, params)
  if has_011 then
    return client:notify(method, params)
  end
  return client.notify(method, params)
end
local function lsp_cancel(client, request_id)
  if has_011 then
    return client:cancel_request(request_id)
  end
  return client.cancel_request(request_id)
end
local function lsp_exec(client, command, buf)
  if has_011 then
    return client:exec_cmd(command, { bufnr = buf })
  end
  return client.request(
    "workspace/executeCommand",
    { command = command.command, arguments = command.arguments },
    nil,
    buf
  )
end

function M.client_for(buf)
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
    if client.name:lower():find("copilot", 1, true) then
      return client
    end
  end
end

--- Copilot produces no suggestions for a document it was never told has
--- focus; notify once per buffer switch.
function M.did_focus(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
    return
  end
  local client = M.client_for(buf)
  if not client then
    return
  end
  local uri = vim.uri_from_bufnr(buf)
  if focused[client.id] ~= uri then
    focused[client.id] = uri
    lsp_notify(client, "textDocument/didFocus", { textDocument = { uri = uri } })
  end
end

--- Byte column on `line` for an LSP character offset in the client's encoding.
local function byte_col(client, line, character)
  local ok, col =
    pcall(vim.str_byteindex, line, client.offset_encoding or "utf-16", character, false)
  return ok and col or #line
end

--- Widen an LSP edit (range + text, possibly mid-line) into the whole-line
--- prediction shape ui.show expects, or nil for a no-op.
local function to_prediction(client, buf, edit)
  local range = edit.range
  local start_line = range.start.line + 1
  local end_line = range["end"].line + 1
  local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
  if #lines == 0 then
    return nil
  end
  local prefix = lines[1]:sub(1, byte_col(client, lines[1], range.start.character))
  local suffix = lines[#lines]:sub(byte_col(client, lines[#lines], range["end"].character) + 1)
  local replacement = vim.split(prefix .. edit.text .. suffix, "\n", { plain = true })
  if vim.deep_equal(replacement, lines) then
    return nil
  end
  return { start_line = start_line, end_line = end_line, replacement = replacement }
end

--- Request a suggestion for buf; cb(prediction?, err?) runs on the main loop.
--- Returns true when a request was dispatched.
function M.request(buf, cb)
  local client = M.client_for(buf)
  if not client then
    cb(nil, "no Copilot LSP client attached (needs copilot-language-server; see :checkhealth nextedit)")
    return false
  end
  M.did_focus(buf)
  if inflight then
    local prev = vim.lsp.get_client_by_id(inflight.client_id)
    if prev then
      lsp_cancel(prev, inflight.request_id)
    end
    inflight = nil
  end
  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  params.textDocument.version = vim.lsp.util.buf_versions[buf]
  params.context = { triggerKind = 2 } -- automatic
  local ok, request_id = lsp_request(client, "textDocument/copilotInlineEdit", params, function(err, res, ctx)
    if inflight and inflight.request_id == ctx.request_id then
      inflight = nil
    end
    if err then
      return cb(nil, err.message or vim.inspect(err))
    end
    local uri = vim.uri_from_bufnr(buf)
    for _, edit in ipairs(res and res.edits or {}) do
      local doc = edit.textDocument
      -- Only edits for this buffer at its current version: anything else is
      -- stale or out of scope.
      if doc and doc.uri == uri and doc.version == vim.lsp.util.buf_versions[buf] then
        local pred = to_prediction(client, buf, edit)
        if pred then
          if edit.command then
            -- Telling the server an edit was applied is what makes it
            -- propose the next one in the chain.
            pred.on_accept = function()
              lsp_exec(client, edit.command, buf)
            end
          end
          return cb(pred, nil)
        end
      end
    end
    cb(nil, nil)
  end, buf)
  if ok and request_id then
    inflight = { client_id = client.id, request_id = request_id }
    return true
  end
  return false
end

return M
