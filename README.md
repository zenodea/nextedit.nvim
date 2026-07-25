# nextedit.nvim

Cursor-style next-edit prediction for Neovim. As you type, it predicts the
edit you are about to make — based on what you have *been* editing, not just
the text at the cursor — and shows it as a diff overlay you accept with
`<Tab>`.

Classic completion plugins guess the text that continues at your cursor.
Next-edit prediction watches the *changes* you make instead. Rename a
variable, and it offers the same rename at the next usage. Change a function
signature, and it offers to fix the call sites nearby. Start typing a line,
and it offers to finish it. Accepting an edit requests the next prediction
automatically, so repetitive changes become Tab, Tab, Tab.

## Features

- **Edit-history-aware predictions**: recent diffs of your buffer are sent as
  context, which is what makes it "next edit" rather than autocomplete
- **Six provider configurations** — hosted or fully local:
  Anthropic (default), GitHub Copilot, OpenAI, Mercury, Ollama, and Zed's
  Zeta models
- **Diff overlay rendering**: lines that would change are highlighted,
  proposed lines appear below; `<Tab>` accepts, `<C-]>` dismisses
- **Fast and non-blocking**: a Rust sidecar keeps HTTP and JSON off the
  editor loop; requests are debounced, and predictions that finish after
  you kept typing are shifted to their new position — they are only
  dropped when your edits touched the predicted lines themselves
- **Validated output**: model replies are schema-checked, clamped to the
  excerpt, and no-op edits are discarded before they reach the editor

## Requirements

- Neovim 0.10+
- Rust toolchain (to build the server)
- Credentials for your chosen provider (see below), or a local model server

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

Or from a local clone: build with `cd server && cargo build --release`, add
the repo to your runtimepath, and call `require("nextedit").setup()`.

## Usage

Just type. After a short pause (150 ms default) a prediction may appear: the
lines it would replace are highlighted (`NextEditOld`), the proposed lines
show underneath (`NextEditNew`).

| Key / command      | Action                                   |
| ------------------ | ---------------------------------------- |
| `<Tab>`            | Accept the prediction (falls through to normal `<Tab>` when none is shown) |
| `<C-]>`            | Dismiss the prediction                   |
| `:NextEdit`        | Request a prediction now                 |
| `:NextEditRestart` | Restart the server process               |
| `:checkhealth nextedit` | Diagnose binary, server and credential problems |

## Providers

| provider    | endpoint (default)      | default model      | credentials                      |
| ----------- | ----------------------- | ------------------ | -------------------------------- |
| `anthropic` | api.anthropic.com       | `claude-haiku-4-5` | `ANTHROPIC_API_KEY`              |
| `copilot`   | api.githubcopilot.com   | `gpt-4.1`          | Copilot sign-in (see below)      |
| `openai`    | api.openai.com/v1       | `gpt-5-mini`       | `OPENAI_API_KEY`                 |
| `mercury`   | api.inceptionlabs.ai/v1 | `mercury-2`        | `INCEPTION_API_KEY`              |
| `ollama`    | localhost:11434/v1      | `qwen2.5-coder:7b` | none                             |
| `zeta`      | localhost:11434/v1      | `zeta`             | none                             |
| `zeta2`     | localhost:11434/v1      | `zeta2`            | none                             |

Notes:

- **anthropic** uses structured outputs, so the reply is schema-validated
  JSON, never free text to parse.
- **copilot** reuses the GitHub OAuth token stored by
  [copilot.lua](https://github.com/zbirenbaum/copilot.lua) or copilot.vim —
  sign in once with `:Copilot auth` and it works with your existing Copilot
  subscription. Any model available to Copilot chat can be set via `model`.
- **mercury** is Inception Labs' diffusion coder; at ~1000 tok/s it is a
  particularly good latency fit for edit prediction. `mercury-2` is a reasoning
  model, so requests ask for `reasoning_effort: instant` — left at the default
  it spends several hundred tokens thinking before emitting the edit, which
  dominates the round trip (~2.9s median vs ~0.4s measured). Override with
  `NEXTEDIT_REASONING_EFFORT` (`instant`, `low`, `medium`, `high`) if you want
  to trade latency back for prediction quality.
- **openai** works with any OpenAI-compatible chat completions server —
  point `api_url` at llama.cpp, vLLM, OpenRouter, Groq, LM Studio, etc.
  Requests include [predicted outputs](https://platform.openai.com/docs/guides/predicted-outputs)
  seeded with the code around the cursor, which speeds up decoding on models
  that support them; servers that reject the field are retried without it.
- **zeta** speaks the native editable-region rewrite format of
  [Zed's Zeta models](https://huggingface.co/zed-industries) over a raw
  completions endpoint — serve one locally with Ollama, llama.cpp or vLLM.
- **zeta2** speaks the newer [Zeta 2](https://huggingface.co/zed-industries/zeta-2)
  dialect (Seed-Coder-8B): fill-in-the-middle in SPM order with the editable
  region delimited by git merge markers, matching Zed's `V0211SeedCoder` format.

  Both zeta providers build the prompt themselves and need it passed through
  **verbatim**, so use a server that does not apply a chat template on top —
  llama.cpp is the safe choice:

  ```bash
  llama-server -hf bartowski/zed-industries_zeta-GGUF:Q4_K_M --port 8080 -c 8192
  ```

  ```lua
  require("nextedit").setup({ provider = "zeta2", api_url = "http://localhost:8080/v1" })
  ```

  Both rewrite the whole editable region rather than emitting a minimal edit, so
  output length — and so latency — is set by `EDITABLE_RADIUS` in
  `server/src/provider/zeta.rs` (17 lines by default). Lower it if local
  inference feels slow.

## Configuration

Defaults shown:

```lua
require("nextedit").setup({
  debounce_ms = 150,     -- pause after typing before requesting a prediction
  context_lines = 40,    -- buffer lines sent above and below the cursor
  accept_key = "<Tab>",
  dismiss_key = "<C-]>",
  server_cmd = nil,      -- override the server binary, e.g. { "/path/to/nextedit-server" }
  provider = nil,        -- "anthropic" (default), "copilot", "openai", "mercury", "ollama" or "zeta"
  model = nil,           -- provider-specific model name
  api_url = nil,         -- override the provider's endpoint
  api_key = nil,         -- prefer the provider's env var; for keyless local setups
})
```

Examples:

```lua
-- GitHub Copilot, using your existing sign-in
require("nextedit").setup({ provider = "copilot" })

-- Mercury
require("nextedit").setup({ provider = "mercury" })

-- Local model via Ollama
require("nextedit").setup({ provider = "ollama", model = "qwen2.5-coder:7b" })

-- Zeta served by llama.cpp
require("nextedit").setup({ provider = "zeta", api_url = "http://localhost:8080/v1" })
```

The same settings are also read from the environment (the Lua options
override per key): `NEXTEDIT_PROVIDER`, `NEXTEDIT_MODEL`, `NEXTEDIT_API_URL`,
`NEXTEDIT_API_KEY`, with provider key fallbacks `ANTHROPIC_API_KEY`,
`OPENAI_API_KEY`, `INCEPTION_API_KEY`.

Highlights: `NextEditOld` links to `DiffDelete`, `NextEditNew` to `DiffAdd`.
Override either with `:hi` or `nvim_set_hl`.

## How it works

The plugin is split in two. On the Lua side, `init.lua` handles autocmds,
debouncing and keymaps, `diff.lua` keeps a short history of your recent edits
(`vim.diff` of buffer snapshots), and `ui.lua` renders predictions as
extmarks. It talks over stdio — one JSON object per line — to a Rust sidecar
(`server/`) that owns all network traffic, so the editor loop never blocks on
HTTP; tokio also makes cancelling superseded requests trivial.

A prediction cycle:

1. On every text change the current overlay is dismissed and a debounce timer
   restarts.
2. When the timer fires, the excerpt around the cursor, the cursor line, and
   the recent-edit history go to the server. A new request aborts any
   in-flight one; the Lua side also drops responses whose id or changedtick
   is stale.
3. The server prompts the configured provider — structured JSON for
   Anthropic/OpenAI-style backends, an editable-region rewrite for Zeta —
   validates the edit against the excerpt, and discards no-ops.
4. `ui.lua` renders the edit as extmarks. `<Tab>` applies it with
   `nvim_buf_set_lines`, which fires `TextChanged`, so a follow-up prediction
   is requested automatically. That is what gives the Tab-Tab-Tab chaining
   feel.

## Roadmap

- Multi-location jumps: predict a follow-up edit elsewhere in the file with a
  Tab-to-jump hint, like Cursor
- Cursor-column tracking for more precise predictions
- Inline ghost text for pure insertions instead of the line-based overlay
- Prompt caching and streaming for lower latency
- Partial accept (word or line at a time)
- Incremental edit tracking instead of whole-buffer snapshots

## Limitations (deliberate, for now)

- Line-based edits only: replacements render below the affected lines rather
  than as inline ghost text
- One prediction at a time, near the cursor, no multi-location jumps yet
- Whole-buffer snapshot per prediction cycle; fine for normal files, wasteful
  for huge ones
- No streaming, no caching

## License

MIT — see [LICENSE](LICENSE).
