mod anthropic;
mod copilot;
mod openai;
mod zeta;

use std::time::Duration;

use anyhow::{bail, Context, Result};
use serde::Deserialize;
use serde_json::json;

use crate::protocol::{PredictParams, Prediction};

pub enum Provider {
    Anthropic(anthropic::Anthropic),
    Copilot(copilot::Copilot),
    OpenAi(openai::OpenAi),
    Zeta(zeta::Zeta),
}

impl Provider {
    /// Selected by NEXTEDIT_PROVIDER: anthropic (default), copilot, openai,
    /// mercury, ollama, zeta or zeta2.
    pub fn from_env() -> Result<Self> {
        let name = std::env::var("NEXTEDIT_PROVIDER").unwrap_or_else(|_| "anthropic".into());
        match name.as_str() {
            "anthropic" => Ok(Self::Anthropic(anthropic::Anthropic::from_env()?)),
            "copilot" => Ok(Self::Copilot(copilot::Copilot::from_env()?)),
            "openai" | "mercury" | "ollama" => Ok(Self::OpenAi(openai::OpenAi::from_env(&name)?)),
            "zeta" => Ok(Self::Zeta(zeta::Zeta::from_env(zeta::Format::V1)?)),
            "zeta2" => Ok(Self::Zeta(zeta::Zeta::from_env(zeta::Format::V2)?)),
            other => bail!(
                "unknown NEXTEDIT_PROVIDER {other:?} (expected anthropic, copilot, openai, mercury, ollama, zeta or zeta2)"
            ),
        }
    }

    pub async fn predict(&self, p: &PredictParams) -> Result<Prediction> {
        match self {
            Self::Anthropic(x) => x.predict(p).await,
            Self::Copilot(x) => x.predict(p).await,
            Self::OpenAi(x) => x.predict(p).await,
            Self::Zeta(x) => x.predict(p).await,
        }
    }
}

pub(crate) const SYSTEM_PROMPT: &str = "\
You are a next-edit prediction engine embedded in a code editor.

From the user's recent edits and the current buffer excerpt, predict the single \
edit they are most likely to make next — the natural continuation of what they \
are doing: finishing the line they are typing, applying the change they just \
made to a similar spot, or fixing an inconsistency their last edit introduced.

Rules:
- <|cursor|> in the excerpt marks the exact cursor position. It is a marker, \
not buffer text: never include it in the replacement.
- The edit replaces whole lines start_line..end_line (absolute numbers as shown \
in the excerpt, inclusive).
- replacement is the complete new text for that range. To insert new lines after \
line N without changing it, use start_line = end_line = N and include line N's \
current text in the replacement.
- Prefer one small, high-confidence edit at or near the cursor. Do not rewrite \
code the user has not touched.
- Match the file's existing style exactly (indentation, naming, quoting).
- Diagnostics, when present, usually point at the fix the user is about to \
make; an edit that resolves one near the cursor is a strong prediction.
- If you have no confident prediction, set has_edit to false. A wrong prediction \
is worse than none.";

// The JSON instructions live in the prompt rather than response_format because
// not every compatible server supports json_schema, and several reject unknown
// response_format values outright.
pub(crate) const FORMAT_INSTRUCTIONS: &str = "\n\nRespond with only a JSON object shaped as \
{\"has_edit\": boolean, \"start_line\": integer, \"end_line\": integer, \"replacement\": string} \
where replacement is the full new text for the replaced lines, newline-separated, \
and an empty string deletes them. No prose, no code fences.";

/// Request body for an OpenAI-style chat completions call. Only universally
/// supported fields: reasoning-model endpoints reject max_tokens and
/// non-default temperature.
pub(crate) fn chat_body(model: &str, p: &PredictParams) -> serde_json::Value {
    json!({
        "model": model,
        "messages": [
            { "role": "system", "content": format!("{SYSTEM_PROMPT}{FORMAT_INSTRUCTIONS}") },
            { "role": "user", "content": user_prompt(p) },
        ],
    })
}

/// Pull the assistant text out of an OpenAI-style chat completions response.
pub(crate) fn parse_chat_content(text: &str) -> Result<String> {
    #[derive(Deserialize)]
    struct ApiResponse {
        choices: Vec<Choice>,
    }
    #[derive(Deserialize)]
    struct Choice {
        message: Message,
    }
    #[derive(Deserialize)]
    struct Message {
        #[serde(default)]
        content: String,
    }
    let api: ApiResponse = serde_json::from_str(text).context("unexpected API response shape")?;
    let choice = api.choices.into_iter().next().context("no choices in API response")?;
    Ok(choice.message.content)
}

/// What we ask the model to produce, enforced by structured outputs where the
/// API supports them and by lenient parsing otherwise.
#[derive(Deserialize)]
pub(crate) struct ModelEdit {
    pub has_edit: bool,
    pub start_line: usize,
    pub end_line: usize,
    pub replacement: String,
}

pub(crate) fn http_client() -> reqwest::Client {
    reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(5))
        .timeout(Duration::from_secs(20))
        .build()
        .expect("client builds")
}

pub(crate) const CURSOR_MARKER: &str = "<|cursor|>";

/// Insert `marker` into `line` at byte `col`, clamped to the line and nudged
/// back onto a character boundary.
pub(crate) fn insert_marker(line: &str, col: usize, marker: &str) -> String {
    let mut col = col.min(line.len());
    while !line.is_char_boundary(col) {
        col -= 1;
    }
    format!("{}{}{}", &line[..col], marker, &line[col..])
}

pub(crate) fn user_prompt(p: &PredictParams) -> String {
    use std::fmt::Write;
    let mut s = String::new();
    let _ = writeln!(s, "File: {} (filetype: {})\n", p.path, p.filetype);
    s.push_str("Recent edits, oldest first:\n");
    if p.recent_edits.is_empty() {
        s.push_str("(none)\n");
    }
    for d in &p.recent_edits {
        let _ = writeln!(s, "```diff\n{}\n```", d.trim_end());
    }
    let _ = writeln!(s, "\nBuffer excerpt ({CURSOR_MARKER} marks the cursor):");
    for (i, line) in p.excerpt_lines.iter().enumerate() {
        let n = p.excerpt_start + i;
        if n == p.cursor_line {
            let _ = writeln!(s, "{n:5}| {}", insert_marker(line, p.cursor_col, CURSOR_MARKER));
        } else {
            let _ = writeln!(s, "{n:5}| {line}");
        }
    }
    if !p.diagnostics.is_empty() {
        s.push_str("\nDiagnostics in the excerpt:\n");
        for d in &p.diagnostics {
            let _ = writeln!(s, "{d}");
        }
    }
    s.push_str("\nPredict the user's next edit.");
    s
}

pub(crate) fn edit_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "properties": {
            "has_edit": {
                "type": "boolean",
                "description": "false when there is no confident prediction"
            },
            "start_line": {
                "type": "integer",
                "description": "first buffer line to replace (absolute, inclusive)"
            },
            "end_line": {
                "type": "integer",
                "description": "last buffer line to replace (absolute, inclusive)"
            },
            "replacement": {
                "type": "string",
                "description": "full new text for the replaced lines, newline-separated; empty string deletes the lines"
            }
        },
        "required": ["has_edit", "start_line", "end_line", "replacement"],
        "additionalProperties": false
    })
}

/// Parse a ModelEdit from model text that may be wrapped in code fences or prose.
pub(crate) fn parse_model_edit(text: &str) -> Result<ModelEdit> {
    if let Ok(edit) = serde_json::from_str(text) {
        return Ok(edit);
    }
    let start = text.find('{');
    let end = text.rfind('}');
    if let (Some(start), Some(end)) = (start, end) {
        if start < end {
            return serde_json::from_str(&text[start..=end])
                .context("model output did not match the edit schema");
        }
    }
    bail!("model output contained no JSON object")
}

/// Clamp the model's edit to the excerpt and drop no-ops.
pub(crate) fn validate(edit: ModelEdit, p: &PredictParams) -> Prediction {
    if !edit.has_edit {
        return Prediction::none();
    }
    let first = p.excerpt_start;
    let last = p.excerpt_start + p.excerpt_lines.len().saturating_sub(1);
    if edit.start_line < first || edit.end_line > last || edit.start_line > edit.end_line {
        return Prediction::none();
    }
    // Models occasionally echo the cursor marker back; it is never buffer text.
    let replacement = edit.replacement.replace(CURSOR_MARKER, "");
    let replacement: Vec<String> = if replacement.is_empty() {
        vec![]
    } else {
        replacement.split('\n').map(str::to_string).collect()
    };
    let current = &p.excerpt_lines[edit.start_line - first..=edit.end_line - first];
    if current == replacement.as_slice() {
        return Prediction::none();
    }
    Prediction { has_edit: true, start_line: edit.start_line, end_line: edit.end_line, replacement }
}
