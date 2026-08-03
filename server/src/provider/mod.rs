mod anthropic;
mod copilot;
mod openai;
mod zeta;

use std::sync::OnceLock;
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
    /// mercury, gemini, xai, mistral, openrouter, ollama, zeta or zeta2.
    pub fn from_env() -> Result<Self> {
        let name = std::env::var("NEXTEDIT_PROVIDER").unwrap_or_else(|_| "anthropic".into());
        match name.as_str() {
            "anthropic" => Ok(Self::Anthropic(anthropic::Anthropic::from_env()?)),
            "copilot" => Ok(Self::Copilot(copilot::Copilot::from_env()?)),
            "openai" | "mercury" | "ollama" | "gemini" | "xai" | "mistral" | "openrouter" => {
                Ok(Self::OpenAi(openai::OpenAi::from_env(&name)?))
            }
            "zeta" => Ok(Self::Zeta(zeta::Zeta::from_env(zeta::Format::V1)?)),
            "zeta2" => Ok(Self::Zeta(zeta::Zeta::from_env(zeta::Format::V2)?)),
            other => bail!(
                "unknown NEXTEDIT_PROVIDER {other:?} (expected anthropic, copilot, openai, \
                 mercury, gemini, xai, mistral, openrouter, ollama, zeta or zeta2)"
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
- The edit may target the excerpt or any \"related region\" shown; use a \
related region when the user's last edit clearly needs the same change there \
(a renamed function's remaining call site, say). When the region is in a \
different file, set \"path\" to that file's path exactly as shown; otherwise \
omit \"path\".
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
and an empty string deletes them. Add \"path\": string only when the edit is in a \
related region from a different file. No prose, no code fences.";

/// Two worked examples sent as prior conversation turns: a rename propagated
/// to its call site (the canonical next edit) and a confident no-edit. They
/// anchor the output shape and make "no edit" a real option; the user halves
/// are rendered by `user_prompt` itself so they can never drift from the live
/// prompt format.
pub(crate) fn examples() -> &'static [(String, String)] {
    static EXAMPLES: OnceLock<Vec<(String, String)>> = OnceLock::new();
    EXAMPLES.get_or_init(|| {
        let lines = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        let rename = PredictParams {
            path: "src/user.py".into(),
            filetype: "python".into(),
            cursor_line: 12,
            cursor_col: 14,
            excerpt_start: 12,
            excerpt_lines: lines(&[
                "def fetch_user(id):",
                "    return db.lookup(id)",
                "",
                "def handler(req):",
                "    user = get_user(req.id)",
                "    return render(user)",
            ]),
            recent_edits: vec![crate::protocol::RecentEdit {
                path: "src/user.py".into(),
                diff: "@@ -12,2 +12,2 @@\n-def get_user(id):\n+def fetch_user(id):\n     return db.lookup(id)\n".into(),
            }],
            diagnostics: vec!["line 16 [ERROR]: undefined name 'get_user'".into()],
            outline: vec![],
            extra_regions: vec![],
        };
        let rename_edit = "{\"has_edit\": true, \"start_line\": 16, \"end_line\": 16, \
             \"replacement\": \"    user = fetch_user(req.id)\"}";
        let complete = PredictParams {
            path: "src/circle.py".into(),
            filetype: "python".into(),
            cursor_line: 4,
            cursor_col: 27,
            excerpt_start: 1,
            excerpt_lines: lines(&[
                "import math",
                "",
                "def area(r):",
                "    return math.pi * r ** 2",
            ]),
            recent_edits: vec![crate::protocol::RecentEdit {
                path: "src/circle.py".into(),
                diff: "@@ -3,1 +3,2 @@\n def area(r):\n+    return math.pi * r ** 2\n".into(),
            }],
            diagnostics: vec![],
            outline: vec![],
            extra_regions: vec![],
        };
        let no_edit =
            "{\"has_edit\": false, \"start_line\": 0, \"end_line\": 0, \"replacement\": \"\"}";
        vec![
            (user_prompt(&rename), rename_edit.to_string()),
            (user_prompt(&complete), no_edit.to_string()),
        ]
    })
}

/// Request body for an OpenAI-style chat completions call. Only universally
/// supported fields: reasoning-model endpoints reject max_tokens and
/// non-default temperature.
pub(crate) fn chat_body(model: &str, p: &PredictParams) -> serde_json::Value {
    let mut messages = vec![
        json!({ "role": "system", "content": format!("{SYSTEM_PROMPT}{FORMAT_INSTRUCTIONS}") }),
    ];
    for (user, assistant) in examples() {
        messages.push(json!({ "role": "user", "content": user }));
        messages.push(json!({ "role": "assistant", "content": assistant }));
    }
    messages.push(json!({ "role": "user", "content": user_prompt(p) }));
    json!({ "model": model, "messages": messages })
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
    /// Set when the edit targets a related region from a different file.
    #[serde(default)]
    pub path: Option<String>,
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
        let _ = writeln!(s, "User edited {}:\n```diff\n{}\n```", d.path, d.diff.trim_end());
    }
    if !p.outline.is_empty() {
        s.push_str("\nFile outline (definitions across the whole file):\n");
        for line in &p.outline {
            let _ = writeln!(s, "{line}");
        }
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
    for r in &p.extra_regions {
        if r.path == p.path {
            s.push_str("\nRelated region elsewhere in this file (also editable):\n");
        } else {
            let _ = writeln!(s, "\nRelated region in {} (also editable):", r.path);
        }
        for (i, line) in r.lines.iter().enumerate() {
            let _ = writeln!(s, "{:5}| {}", r.start + i, line);
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
            },
            "path": {
                "type": "string",
                "description": "only when the edit is in a related region from a different file: that file's path exactly as shown"
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

/// Clamp the model's edit to lines it was actually shown — the excerpt or one
/// extra region — and drop no-ops.
pub(crate) fn validate(edit: ModelEdit, p: &PredictParams) -> Prediction {
    if !edit.has_edit || edit.start_line > edit.end_line {
        return Prediction::none();
    }
    // The region (excerpt or extra) that fully contains the edit, in the
    // file the edit names (models sometimes echo the current path; treat
    // that as "no path").
    let edit_path = edit.path.as_deref().filter(|path| *path != p.path);
    let mut regions = std::iter::once((p.path.as_str(), p.excerpt_start, &p.excerpt_lines))
        .chain(p.extra_regions.iter().map(|r| (r.path.as_str(), r.start, &r.lines)));
    let Some((path, start, lines)) = regions.find(|(path, start, lines)| {
        *path == edit_path.unwrap_or(&p.path)
            && edit.start_line >= *start
            && edit.end_line <= start + lines.len().saturating_sub(1)
    }) else {
        return Prediction::none();
    };
    // Models occasionally echo the cursor marker back; it is never buffer text.
    let replacement = edit.replacement.replace(CURSOR_MARKER, "");
    let replacement: Vec<String> = if replacement.is_empty() {
        vec![]
    } else {
        replacement.split('\n').map(str::to_string).collect()
    };
    let current = &lines[edit.start_line - start..=edit.end_line - start];
    if current == replacement.as_slice() {
        return Prediction::none();
    }
    Prediction {
        has_edit: true,
        start_line: edit.start_line,
        end_line: edit.end_line,
        replacement,
        path: (path != p.path).then(|| path.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn insert_marker_clamps_and_respects_char_boundaries() {
        assert_eq!(insert_marker("abc", 1, "|"), "a|bc");
        assert_eq!(insert_marker("abc", 99, "|"), "abc|");
        assert_eq!(insert_marker("héllo", 2, "|"), "h|éllo"); // 2 is inside the 'é'
    }

    #[test]
    fn validate_accepts_edit_inside_an_extra_region() {
        let p = PredictParams {
            path: "f.py".into(),
            filetype: "python".into(),
            cursor_line: 10,
            cursor_col: 0,
            excerpt_start: 10,
            excerpt_lines: vec!["def fetch_user(id):".into()],
            recent_edits: vec![],
            diagnostics: vec![],
            outline: vec![],
            extra_regions: vec![crate::protocol::Region {
                path: "other.py".into(),
                start: 200,
                lines: vec!["x = get_user(1)".into()],
            }],
        };
        let edit = ModelEdit {
            has_edit: true,
            start_line: 200,
            end_line: 200,
            replacement: "x = fetch_user(1)".into(),
            path: Some("other.py".into()),
        };
        let pred = validate(edit, &p);
        assert!(pred.has_edit);
        assert_eq!((pred.start_line, pred.end_line), (200, 200));
        assert_eq!(pred.path.as_deref(), Some("other.py"));
        // ...but an edit whose range and path do not match a region is rejected.
        let stray = ModelEdit {
            has_edit: true,
            start_line: 200,
            end_line: 200,
            replacement: "whatever".into(),
            path: None, // claims the current file, but 200 is only in other.py
        };
        assert!(!validate(stray, &p).has_edit);
    }

    #[test]
    fn examples_render_in_the_live_prompt_format() {
        let ex = examples();
        assert_eq!(ex.len(), 2);
        assert!(ex[0].0.contains(CURSOR_MARKER));
        assert!(ex[0].0.contains("Diagnostics in the excerpt:"));
        assert!(ex[1].1.contains("\"has_edit\": false"));
    }
}
