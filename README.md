# nextedit.nvim

Cursor-style next-edit prediction for Neovim. As you type, it predicts the edit
you are about to make, based on what you have *been* editing, not just the text
at the cursor, and shows it as a diff overlay you accept with `<Tab>`.

## What it does

Classic completion plugins guess the text that continues at your cursor.
Next-edit prediction is different: it watches the *changes* you make. Rename a
variable, and it offers the same rename at the next usage. Change a function
signature, and it offers to fix the call sites nearby. Start typing a line, and
it offers to finish it. Predictions render as a small diff (old lines
highlighted, proposed lines shown underneath) and one keypress applies them.

Accepting an edit triggers the next prediction automatically, so repetitive
changes become Tab, Tab, Tab.

## Features

- Edit-history-aware predictions: recent diffs of your buffer are sent as
  context, which is what makes it "next edit" rather than autocomplete
- Diff overlay rendering: lines that would change are highlighted, proposed
  lines appear below them
- `<Tab>` to accept, `<C-]>` to dismiss, both configurable
- Prediction chaining: accepting an edit requests the next one
- Debounced, cancellable requests: a new keystroke aborts the in-flight
  prediction, and stale responses are dropped by id and changedtick
- Rust sidecar server keeps all network and JSON work off the editor loop
- Multiple providers:
  - **Anthropic** (default, Claude Haiku 4.5) with structured outputs, so the
    model reply is schema-validated JSON, never free text to parse
  - **OpenAI-compatible** chat endpoints: OpenAI, **Mercury** (Inception Labs'
    diffusion coder, very low latency), **Ollama**, llama.cpp, vLLM, OpenRouter
  - **Zeta**: Zed's open edit-prediction models, self-hosted behind any
    OpenAI-compatible completions endpoint, using Zeta's native
    editable-region rewrite format instead of JSON
- Server-side validation: out-of-range and no-op edits are discarded before
  they reach the editor

## Upcoming features

- Multi-location jumps: predict a follow-up edit elsewhere in the file with a
  Tab-to-jump hint, like Cursor
- Inline ghost text for pure insertions instead of the line-based overlay
- Copilot NES as a provider
- Prompt caching and streaming for lower latency
- Partial accept (word or line at a time)
- Incremental edit tracking instead of whole-buffer snapshots

## Architecture

```
+-------------------------- Neovim --------------------------+
|  init.lua    orchestration: autocmds, debounce, keymaps    |
|  diff.lua    edit history (vim.diff of buffer snapshots)   |
|  ui.lua      overlay rendering + accept (extmarks)         |
|  server.lua  child process + JSON-lines RPC                |
+-----------------------------+------------------------------+
                              | stdio, one JSON object per line
+-----------------------------+------------------------------+
|  nextedit-server (Rust)                                    |
|  main.rs      request loop, cancels superseded requests    |
|  provider/    anthropic | openai-compatible | zeta         |
|  protocol.rs  request/response types                       |
+-----------------------------+------------------------------+
                              | HTTPS
        Anthropic / OpenAI / Mercury / Ollama / Zeta model
```

Why the split? The Lua side must never block the editor, and the
latency-critical work (HTTP, cancellation of stale requests, JSON handling) is
much nicer on tokio than on Neovim's event loop.

## Requirements

- Neovim 0.10+
- Rust toolchain (to build the server)
- An API key for your chosen provider in the environment Neovim starts from
  (`ANTHROPIC_API_KEY` for the default provider), or a local model server

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

Or from a local clone: build with `cd server && cargo build --release`, add the
repo to your runtimepath, and call `require("nextedit").setup()`.

## Usage

Just type. After a short pause (300 ms default) a prediction may appear: the
lines it would replace are highlighted (`NextEditOld`), the proposed lines show
underneath (`NextEditNew`).

| Key / command      | Action                                   |
| ------------------ | ---------------------------------------- |
| `<Tab>`            | Accept the prediction (falls through to normal `<Tab>` when none is shown) |
| `<C-]>`            | Dismiss the prediction                   |
| `:NextEdit`        | Request a prediction now                 |
| `:NextEditRestart` | Restart the server process               |

## Configuration

Defaults shown:

```lua
require("nextedit").setup({
  debounce_ms = 300,     -- pause after typing before requesting a prediction
  context_lines = 40,    -- buffer lines sent above and below the cursor
  accept_key = "<Tab>",
  dismiss_key = "<C-]>",
  server_cmd = nil,      -- override the server binary, e.g. { "/path/to/nextedit-server" }
  provider = nil,        -- "anthropic" (default), "openai", "mercury", "ollama" or "zeta"
  model = nil,           -- provider-specific model name
  api_url = nil,         -- override the provider's endpoint
  api_key = nil,         -- prefer the provider's env var; for keyless local setups
})
```

### Providers

| provider    | endpoint (default)                | default model      | API key env        |
| ----------- | --------------------------------- | ------------------ | ------------------ |
| `anthropic` | api.anthropic.com                 | `claude-haiku-4-5` | `ANTHROPIC_API_KEY`|
| `openai`    | api.openai.com/v1                 | `gpt-5-mini`       | `OPENAI_API_KEY`   |
| `mercury`   | api.inceptionlabs.ai/v1           | `mercury-coder`    | `INCEPTION_API_KEY`|
| `ollama`    | localhost:11434/v1                | `qwen2.5-coder:7b` | none               |
| `zeta`      | localhost:11434/v1                | `zeta`             | none               |

`openai` works with any OpenAI-compatible chat completions server — point
`api_url` at llama.cpp, vLLM, OpenRouter, Groq, etc. `zeta` speaks Zed's
editable-region rewrite format over a raw completions endpoint and expects a
[Zeta model](https://huggingface.co/zed-industries) served locally.

Examples:

```lua
-- Mercury (diffusion model, ~1000 tok/s, well suited to edit prediction)
require("nextedit").setup({ provider = "mercury" })

-- Local model via Ollama
require("nextedit").setup({ provider = "ollama", model = "qwen2.5-coder:7b" })

-- Zeta served by llama.cpp
require("nextedit").setup({ provider = "zeta", api_url = "http://localhost:8080/v1" })
```

The same settings are also read from the environment (which the Lua options
override per key):

- `NEXTEDIT_PROVIDER`, `NEXTEDIT_MODEL`, `NEXTEDIT_API_URL`, `NEXTEDIT_API_KEY`
- provider key fallbacks: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `INCEPTION_API_KEY`

Highlights: `NextEditOld` links to `DiffDelete`, `NextEditNew` to `DiffAdd`.
Override either with `:hi` or `nvim_set_hl`.

## How a prediction happens

1. On every text change the current overlay is dismissed and a debounce timer
   restarts.
2. When the timer fires, `diff.lua` diffs the buffer against its previous
   snapshot and appends the hunks to a short edit history.
3. The excerpt around the cursor, the cursor line, and the edit history go to
   the Rust server. A new request aborts any in-flight one; the Lua side also
   drops responses whose id or changedtick is stale.
4. The server prompts the configured provider — structured JSON for
   Anthropic/OpenAI-style backends, an editable-region rewrite for Zeta —
   validates the edit against the excerpt, and discards no-ops.
5. `ui.lua` renders the edit as extmarks. `<Tab>` applies it with
   `nvim_buf_set_lines`, which fires `TextChanged`, so a follow-up prediction
   is requested automatically. That is what gives the Tab-Tab-Tab chaining
   feel.

## Limitations (deliberate, for now)

- Line-based edits only: replacements render below the affected lines rather
  than as inline ghost text
- One prediction at a time, near the cursor, no multi-location jumps yet
- Whole-buffer snapshot per prediction cycle; fine for normal files, wasteful
  for huge ones
- No streaming, no caching
