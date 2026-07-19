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
- Anthropic backend (Claude Haiku 4.5 by default) with structured outputs, so
  the model reply is schema-validated JSON, never free text to parse
- Server-side validation: out-of-range and no-op edits are discarded before
  they reach the editor

## Upcoming features

- Multi-location jumps: predict a follow-up edit elsewhere in the file with a
  Tab-to-jump hint, like Cursor
- Inline ghost text for pure insertions instead of the line-based overlay
- More providers behind the same trait: local models via an OpenAI-compatible
  endpoint (llama.cpp, Ollama, Zeta 2), Copilot NES
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
|  provider.rs  prompt building + Anthropic Messages API     |
|  protocol.rs  request/response types                       |
+-----------------------------+------------------------------+
                              | HTTPS
                        Anthropic API (claude-haiku-4-5)
```

Why the split? The Lua side must never block the editor, and the
latency-critical work (HTTP, cancellation of stale requests, JSON handling) is
much nicer on tokio than on Neovim's event loop.

## Requirements

- Neovim 0.10+
- Rust toolchain (to build the server)
- `ANTHROPIC_API_KEY` in the environment Neovim starts from

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
})
```

Environment variables read by the server:

- `ANTHROPIC_API_KEY` (required)
- `NEXTEDIT_MODEL` (default `claude-haiku-4-5`)

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
4. The server prompts Claude with structured outputs (a JSON schema for
   `{has_edit, start_line, end_line, replacement}`), validates the edit against
   the excerpt, and discards no-ops.
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
- No streaming, no caching, single provider
