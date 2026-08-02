# nextedit.nvim

Next-edit prediction for Neovim, in the style of Cursor and Zed. The plugin
watches the edits you make and predicts the one you are about to make next.
The prediction shows up as a diff overlay you accept with `<Tab>`.

Completion plugins guess the text that continues at your cursor. Next-edit
prediction is a different thing: it reasons about your recent changes. Rename
a function and it offers the same rename at the remaining call sites, in the
same file or in another open buffer. Change a signature and it offers to fix
the callers. Accepting an edit requests the next one, so a repetitive change
becomes Tab, Tab, Tab.

## What it does

- Sends your recent edits as diffs, coalesced into meaningful units (one
  entry per rename or change, not one per keystroke) and collected across
  all open buffers.
- Sends the exact cursor position, the diagnostics around it, and a
  treesitter outline of the file, so the model has real context to work
  with.
- Finds the places your last edit points at (an old name that still occurs
  somewhere, a diagnostic mentioning it) and lets the prediction target
  them, even in another file. A `»` sign marks the spot; the first `<Tab>`
  jumps there, the second applies.
- Renders small changes as word-level inline diffs and larger ones as
  highlighted lines with the new text below. While a completion menu is
  open, the preview moves above the change instead of hiding under the
  menu.
- Remembers what you decline. A dismissed suggestion is not proposed again
  until the lines it touched change. Undoing an accepted prediction counts
  as declining it.
- Works with eleven provider setups, hosted or fully local, including
  GitHub's purpose-trained next-edit model via the Copilot LSP.
- Keeps the editor responsive: a small Rust sidecar owns all network
  traffic, requests are debounced and superseded requests are cancelled.
  Late predictions are shifted to their new position instead of thrown
  away. Model replies are schema-checked and clamped to the code the model
  was actually shown.

Also documented as vim help: `:h nextedit`.

## Requirements

- Neovim 0.10+
- A Rust toolchain to build the sidecar (not needed for `copilot-nes`)
- Credentials for your provider, or a local model server
- For `copilot-nes`: the `copilot-language-server` binary. The easiest way
  to get it is adding `zbirenbaum/copilot.lua` as a plugin dependency; its
  bundled server is found and started automatically (needs Node 22+).
  Alternatives: `npm install -g @github/copilot-language-server` or
  `:MasonInstall copilot-language-server`.

## Install

With lazy.nvim:

```lua
{
  "zenodea/nextedit.nvim",
  build = "cd server && cargo build --release",
  config = function()
    require("nextedit").setup()
  end,
}
```

Or with Copilot's native next-edit model, no Rust build required:

```lua
{
  "zenodea/nextedit.nvim",
  dependencies = { "zbirenbaum/copilot.lua" },
  config = function()
    require("nextedit").setup({ provider = "copilot-nes" })
  end,
}
```

## Usage

Just edit. Predictions are requested when you leave insert mode or make a
normal-mode change. With fast providers (mercury, ollama, zeta) they are
also requested as you type; see the `trigger` option. After a short debounce
the overlay appears: replaced lines are highlighted, proposed text shows
inline or below.

| Key / command | Action |
| ------------- | ------ |
| `<Tab>` | Accept the prediction. If it is far from the cursor or in another buffer, the first press jumps to it and the second applies it. Falls through to the normal `<Tab>` when nothing is shown. |
| `<C-]>` | Dismiss, and do not suggest this again until the lines change. |
| `<Esc>` | Dismiss (normal mode). |
| `:NextEdit` | Request a prediction now. |
| `:NextEditRestart` | Restart the sidecar. |
| `:NextEditSignIn` | GitHub device-code sign-in (`copilot-nes` only). |
| `:checkhealth nextedit` | Diagnose binary, server and credential problems. |

## Providers

| provider | endpoint (default) | default model | credentials |
| -------- | ------------------ | ------------- | ----------- |
| `anthropic` | api.anthropic.com | `claude-haiku-4-5` | `ANTHROPIC_API_KEY` |
| `copilot` | api.githubcopilot.com | `gpt-4.1` | Copilot sign-in |
| `copilot-nes` | local Copilot LSP | Copilot's NES model | Copilot sign-in (see Requirements) |
| `openai` | api.openai.com/v1 | `gpt-5-mini` | `OPENAI_API_KEY` |
| `mercury` | api.inceptionlabs.ai/v1 | `mercury-2` | `INCEPTION_API_KEY` |
| `gemini` | generativelanguage.googleapis.com | `gemini-2.5-flash` | `GEMINI_API_KEY` |
| `xai` | api.x.ai/v1 | `grok-code-fast-1` | `XAI_API_KEY` |
| `mistral` | api.mistral.ai/v1 | `codestral-latest` | `MISTRAL_API_KEY` |
| `openrouter` | openrouter.ai/api/v1 | `google/gemini-2.5-flash-lite` | `OPENROUTER_API_KEY` |
| `ollama` | localhost:11434/v1 | `qwen2.5-coder:7b` | none |
| `zeta`, `zeta2` | localhost:11434/v1 | `zeta`, `zeta2` | none |

Notes:

- **anthropic** uses structured outputs, so replies are schema-validated
  JSON rather than free text.
- **copilot** reuses the GitHub OAuth token stored by copilot.lua,
  copilot.vim or VS Code. Sign in once anywhere and it works.
- **copilot-nes** talks LSP to `copilot-language-server`, the same backend
  VS Code and sidekick.nvim use, and the only option here running a model
  actually trained for next-edit prediction. A running Copilot client is
  reused; otherwise the server is started directly. Sign in with
  `:NextEditSignIn` if you have never signed in to Copilot before. The
  sidecar and the plugin's own context pipeline are bypassed; Copilot
  tracks your edits server-side.
- **mercury** is Inception Labs' diffusion coder. At roughly 1000 tokens/s
  it is a very good latency fit. Requests ask for
  `reasoning_effort: instant`; override with `NEXTEDIT_REASONING_EFFORT`
  if you want to trade latency for quality.
- **gemini**, **xai**, **mistral**, **openrouter** speak the OpenAI dialect
  with their own endpoints and key variables. `grok-code-fast-1` and Gemini
  Flash are quick enough that `trigger = "typing"` is worth trying.
- **openai** works with any OpenAI-compatible chat completions server:
  point `api_url` at llama.cpp, vLLM, OpenRouter, Groq, LM Studio and so
  on. Requests include predicted outputs where supported.
- **zeta** and **zeta2** speak the native editable-region formats of
  [Zed's Zeta models](https://huggingface.co/zed-industries), served
  locally. They build their own prompts and need them passed through
  verbatim, so use a server that does not apply a chat template
  (llama.cpp is the safe choice):

  ```bash
  llama-server -hf bartowski/zed-industries_zeta-GGUF:Q4_K_M --port 8080 -c 8192
  ```

  ```lua
  require("nextedit").setup({ provider = "zeta", api_url = "http://localhost:8080/v1" })
  ```

## Configuration

Defaults shown:

```lua
require("nextedit").setup({
  trigger = nil,         -- "boundary" (predict at edit boundaries) or "typing"
                         -- (also predict as you type); defaults to "typing" for
                         -- mercury/ollama/zeta and "boundary" for the rest
  debounce_ms = 150,     -- pause before a request is sent
  context_lines = 40,    -- buffer lines sent above and below the cursor
  accept_key = "<Tab>",
  dismiss_key = "<C-]>",
  server_cmd = nil,      -- override the sidecar binary
  provider = nil,        -- see the table above; default "anthropic"
  model = nil,           -- provider-specific model name
  api_url = nil,         -- override the provider endpoint
  api_key = nil,         -- prefer the provider's env var
  filetypes = { gitcommit = false, gitrebase = false, help = false },
                         -- per-filetype toggle; unlisted filetypes are enabled
  deny_paths = { "%.env", "%.pem$", "secret", "credential" },
                         -- never predict in files matching these Lua patterns,
                         -- so secrets stay out of API requests; setting this
                         -- replaces the default list
  max_lines = 10000,     -- skip buffers larger than this
})
```

The same settings are read from the environment (Lua options win per key):
`NEXTEDIT_PROVIDER`, `NEXTEDIT_MODEL`, `NEXTEDIT_API_URL`,
`NEXTEDIT_API_KEY`, with provider key fallbacks such as `ANTHROPIC_API_KEY`.

For statuslines, `require("nextedit").status()` returns
`{ provider, inflight, last_error }`. Request errors are notified once per
failure streak, then muted until a request succeeds.

Highlights: `NextEditOld` links to `DiffDelete`, `NextEditNew` to `DiffAdd`,
`NextEditSign` (the `»` mark) to `DiagnosticSignInfo`.

## How it works

Two halves. The Lua side handles triggering, context gathering and
rendering: `diff.lua` keeps the edit history (buffer snapshots committed at
edit boundaries, nearby commits merged into one entry), `outline.lua` builds
the treesitter outline, `regions.lua` finds related sites through
diagnostics and a token scan, `render.lua` turns a prediction into extmarks
and `ui.lua` shows, applies, jumps and remembers rejections. It talks over
stdio, one JSON object per line, to a Rust sidecar (`server/`) that owns the
HTTP traffic, so the editor loop never blocks; a new request aborts the
in-flight one.

A cycle: a trigger fires, the debounce timer runs out, and the excerpt
around the cursor plus cursor position, edit history, diagnostics, outline
and related regions go to the server. The server prompts the configured
provider (structured JSON with few-shot examples for chat backends, an
editable-region rewrite for Zeta), validates the reply against the code the
model was shown, and drops no-ops. The Lua side shifts the prediction across
any edits made while the request was in flight, drops it if those edits
touched the predicted lines, and renders it. Accepting fires `TextChanged`,
which requests the next prediction.

The `copilot-nes` provider replaces all of this with LSP requests to
`copilot-language-server` (`lua/nextedit/nes.lua`).

## Development

Run the tests:

```bash
nvim --headless -l tests/run.lua   # Lua: history, regions, rendering, UI flows
cargo test --manifest-path server/Cargo.toml
```

CI runs both suites on every push. `tests/fake-server.py` stands in for the
sidecar so the Lua suite needs no credentials.

## Not there yet

- One prediction at a time. Editable regions cover the cursor excerpt plus
  detected related sites in open buffers, not whole unopened files.
- Whole-buffer snapshots per edit commit; buffers over `max_lines` are
  skipped instead.
- No streaming, no prompt caching, no partial accept.
- No local accept-rate stats yet, so provider comparisons are still vibes.

## License

MIT, see [LICENSE](LICENSE).
