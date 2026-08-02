local M = {}

local KEY_VARS = {
	anthropic = "ANTHROPIC_API_KE",
	openai = "OPENAI_API_KEY",
	mercury = "INCEPTION_API_KEY",
	gemini = "GEMINI_API_KEY",
	xai = "XAI_API_KEY",
	mistral = "MISTRAL_API_KEY",
	openrouter = "OPENROUTER_API_KEY",
}

local function env(name)
	local v = vim.env[name]
	return v ~= nil and v ~= "" and v or nil
end

local function copilot_token_file()
	local dir = (env("XDG_CONFIG_HOME") or vim.env.HOME .. "/.config") .. "/github-copilot"
	for _, file in ipairs({ "apps.json", "hosts.json" }) do
		if vim.uv.fs_stat(dir .. "/" .. file) then
			return dir .. "/" .. file
		end
	end
end

function M.check()
	local h = vim.health
	h.start("nextedit")

	local opts = require("nextedit").current_opts()
	if not opts then
		h.error("setup() has not been called", { 'add require("nextedit").setup() to your config' })
		return
	end

	local provider0 = opts.provider or env("NEXTEDIT_PROVIDER") or "anthropic"
	if provider0 == "copilot-nes" then
		h.info("provider copilot-nes (Copilot LSP; the Rust sidecar is not used)")
		local client
		for _, c in ipairs(vim.lsp.get_clients()) do
			if c.name:lower():find("copilot", 1, true) then
				client = c
				break
			end
		end
		if client then
			h.ok("Copilot LSP client running: " .. client.name)
		else
			local cmd = require("nextedit.nes").server_cmd()
			if cmd then
				h.ok("copilot-language-server found: " .. table.concat(cmd, " ") .. " (starts on demand)")
			else
				h.error("copilot-language-server not found", {
					"add zbirenbaum/copilot.lua as a plugin dependency (its bundled server is used; needs node 22+)",
					"or npm install -g @github/copilot-language-server",
					"or :MasonInstall copilot-language-server",
				})
			end
		end
		local file = copilot_token_file()
		if file then
			h.ok("copilot sign-in found: " .. file)
		else
			h.warn("no Copilot sign-in found", { "run :NextEditSignIn" })
		end
		return
	end

	local cmd = require("nextedit").server_command()
	if vim.fn.executable(cmd[1]) == 1 then
		h.ok("server binary: " .. cmd[1])
	else
		h.error("server binary not found: " .. cmd[1], { "build it with: cd server && cargo build --release" })
	end

	if require("nextedit.server").is_running() then
		h.ok("server is running")
	else
		h.warn("server is not running", { "start it with :NextEditRestart, then check :messages for errors" })
	end

	local provider = opts.provider or env("NEXTEDIT_PROVIDER") or "anthropic"
	local model = opts.model or env("NEXTEDIT_MODEL") or "(provider default)"
	h.info(("provider %s, model %s"):format(provider, model))

	-- The server inherits Neovim's environment, so vim.env is exactly what it sees.
	if opts.api_key or env("NEXTEDIT_API_KEY") then
		h.ok("api key configured explicitly")
	elseif provider == "copilot" then
		local file = copilot_token_file()
		if file then
			h.ok("copilot sign-in found: " .. file)
		else
			h.error("no copilot sign-in found", { "sign in with :Copilot auth (copilot.lua or copilot.vim)" })
		end
	elseif KEY_VARS[provider] then
		if env(KEY_VARS[provider]) then
			h.ok(KEY_VARS[provider] .. " is set")
		else
			h.error(KEY_VARS[provider] .. " is not set in Neovim's environment", {
				"export it in your shell profile and restart Neovim from a new terminal",
			})
		end
	else
		h.ok("provider " .. provider .. " needs no credentials")
	end
end

return M
