-- Owns the Rust child process. One JSON object per line in both directions.
local M = {}

local job = nil
local next_id = 0
local pending = {} -- id -> callback(result, err)
local stdout_tail = ""

local function on_stdout(_, data)
  -- data is a list of chunks; the last element may be a partial line.
  data[1] = stdout_tail .. data[1]
  stdout_tail = table.remove(data)
  for _, line in ipairs(data) do
    if line ~= "" then
      local ok, msg = pcall(vim.json.decode, line)
      if ok and pending[msg.id] then
        local cb = pending[msg.id]
        pending[msg.id] = nil
        cb(msg.result, msg.error)
      end
    end
  end
end

--- env is an optional table of environment variables merged into the server's
--- environment (e.g. { NEXTEDIT_PROVIDER = "ollama" }).
function M.start(cmd, env)
  if job then
    return true
  end
  if vim.fn.executable(cmd[1]) ~= 1 then
    vim.notify(
      ("nextedit: server binary not found at %s\nBuild it with: cd server && cargo build --release"):format(cmd[1]),
      vim.log.levels.ERROR
    )
    return false
  end
  job = vim.fn.jobstart(cmd, {
    env = env and not vim.tbl_isempty(env) and env or nil,
    on_stdout = on_stdout,
    on_stderr = function(_, data)
      local msg = table.concat(data, "\n"):gsub("%s+$", "")
      if msg ~= "" then
        vim.notify("nextedit: " .. msg, vim.log.levels.WARN)
      end
    end,
    on_exit = function(exited, code)
      if exited ~= job then
        return -- a previous server's exit racing a restart; the state belongs to the new one
      end
      job = nil
      pending = {}
      if code ~= 0 and vim.v.exiting == vim.NIL then
        vim.notify("nextedit: server exited with code " .. code, vim.log.levels.WARN)
      end
    end,
  })
  if job <= 0 then
    job = nil
    vim.notify("nextedit: failed to start server", vim.log.levels.ERROR)
    return false
  end
  return true
end

--- Returns the request id, or nil if the server isn't running.
function M.predict(params, cb)
  if not job then
    return nil
  end
  next_id = next_id + 1
  pending[next_id] = cb
  vim.fn.chansend(job, vim.json.encode({ id = next_id, method = "predict", params = params }) .. "\n")
  return next_id
end

function M.is_running()
  return job ~= nil
end

function M.stop()
  if job then
    vim.fn.jobstop(job)
    job = nil
    pending = {}
  end
end

return M
