use anyhow::{bail, Context, Result};
use serde::Deserialize;
use serde_json::json;

use crate::protocol::{PredictParams, Prediction};

use super::http_client;

/// Zed's Zeta family of edit-prediction models, self-hosted behind any
/// OpenAI-compatible completions endpoint (Ollama, llama.cpp, vLLM).
///
/// Zeta is not prompted for JSON: it receives the excerpt with an editable
/// region marked out and rewrites that region. We diff its rewrite against the
/// original lines to recover a start/end/replacement edit.
pub struct Zeta {
    client: reqwest::Client,
    api_url: String,
    api_key: Option<String>,
    model: String,
}

const REGION_START: &str = "<|editable_region_start|>";
const REGION_END: &str = "<|editable_region_end|>";
const CURSOR: &str = "<|user_cursor_is_here|>";

/// Lines around the cursor the model is allowed to rewrite; the rest of the
/// excerpt is read-only context. Small keeps rewrites cheap and focused.
const EDITABLE_RADIUS: usize = 8;

const INSTRUCTION: &str = "\
### Instruction:
You are a code completion assistant and your task is to analyze user edits and \
then rewrite an excerpt that the user provides, suggesting the appropriate \
edits within the excerpt, taking into account the cursor location.";

impl Zeta {
    pub fn from_env() -> Result<Self> {
        let base = std::env::var("NEXTEDIT_API_URL")
            .unwrap_or_else(|_| "http://localhost:11434/v1".into());
        let api_url = format!("{}/completions", base.trim_end_matches('/'));
        let api_key = std::env::var("NEXTEDIT_API_KEY").ok().filter(|k| !k.is_empty());
        let model = std::env::var("NEXTEDIT_MODEL").unwrap_or_else(|_| "zeta".into());
        Ok(Self { client: http_client(), api_url, api_key, model })
    }

    pub async fn predict(&self, p: &PredictParams) -> Result<Prediction> {
        let Some(region) = EditableRegion::around_cursor(p) else {
            return Ok(Prediction::none());
        };
        let body = json!({
            "model": self.model,
            "prompt": build_prompt(p, &region),
            "max_tokens": 2048,
            "temperature": 0,
            "stop": [REGION_END],
        });
        let mut req = self.client.post(&self.api_url).json(&body);
        if let Some(key) = &self.api_key {
            req = req.bearer_auth(key);
        }
        let resp = req.send().await.context("request to completions endpoint failed")?;
        let status = resp.status();
        let text = resp.text().await.context("reading completions response failed")?;
        if !status.is_success() {
            bail!("completions endpoint returned {status}: {text}");
        }

        #[derive(Deserialize)]
        struct ApiResponse {
            choices: Vec<Choice>,
        }
        #[derive(Deserialize)]
        struct Choice {
            #[serde(default)]
            text: String,
        }

        let api: ApiResponse =
            serde_json::from_str(&text).context("unexpected API response shape")?;
        let output = api.choices.first().map(|c| c.text.as_str()).context("no choices")?;
        Ok(region.diff_against(parse_rewrite(output)))
    }
}

/// The editable slice of the excerpt, as 0-based indices into excerpt_lines.
struct EditableRegion<'a> {
    lines: &'a [String],
    /// Absolute 1-based buffer line of lines[0].
    abs_start: usize,
}

impl<'a> EditableRegion<'a> {
    fn around_cursor(p: &'a PredictParams) -> Option<Self> {
        if p.excerpt_lines.is_empty() {
            return None;
        }
        let cursor_idx = p.cursor_line.checked_sub(p.excerpt_start)?;
        if cursor_idx >= p.excerpt_lines.len() {
            return None;
        }
        let start = cursor_idx.saturating_sub(EDITABLE_RADIUS);
        let end = (cursor_idx + EDITABLE_RADIUS).min(p.excerpt_lines.len() - 1);
        Some(Self { lines: &p.excerpt_lines[start..=end], abs_start: p.excerpt_start + start })
    }

    /// Turn the model's rewritten region into a minimal line edit by trimming
    /// the unchanged prefix and suffix.
    fn diff_against(&self, rewritten: Vec<String>) -> Prediction {
        let original = self.lines;
        // An empty completion means the model bailed, not "delete the region".
        if rewritten.iter().all(|l| l.is_empty()) && original != rewritten.as_slice() {
            return Prediction::none();
        }
        let mut pre = 0;
        while pre < original.len() && pre < rewritten.len() && original[pre] == rewritten[pre] {
            pre += 1;
        }
        let mut post = 0;
        while post < original.len() - pre
            && post < rewritten.len() - pre
            && original[original.len() - 1 - post] == rewritten[rewritten.len() - 1 - post]
        {
            post += 1;
        }
        let orig_mid = &original[pre..original.len() - post];
        let new_mid = &rewritten[pre..rewritten.len() - post];
        if new_mid.is_empty() && orig_mid.is_empty() {
            return Prediction::none();
        }
        if orig_mid.is_empty() {
            // Pure insertion: the protocol replaces whole lines, so anchor the
            // inserted lines onto a neighboring unchanged line.
            let anchor = pre.saturating_sub(1);
            let mut replacement = Vec::with_capacity(new_mid.len() + 1);
            if pre > 0 {
                replacement.push(original[anchor].clone());
                replacement.extend(new_mid.iter().cloned());
            } else {
                replacement.extend(new_mid.iter().cloned());
                replacement.push(original[anchor].clone());
            }
            let line = self.abs_start + anchor;
            return Prediction { has_edit: true, start_line: line, end_line: line, replacement };
        }
        Prediction {
            has_edit: true,
            start_line: self.abs_start + pre,
            end_line: self.abs_start + pre + orig_mid.len() - 1,
            replacement: new_mid.to_vec(),
        }
    }
}

fn build_prompt(p: &PredictParams, region: &EditableRegion) -> String {
    use std::fmt::Write;
    let mut s = String::from(INSTRUCTION);
    s.push_str("\n\n### User Edits:\n\n");
    if p.recent_edits.is_empty() {
        s.push_str("(none)\n");
    }
    for d in &p.recent_edits {
        let _ = writeln!(s, "User edited {:?}:\n```diff\n{}\n```\n", p.path, d.trim_end());
    }
    let _ = writeln!(s, "\n### User Excerpt:\n\n```{}", p.path);
    let region_first = region.abs_start - p.excerpt_start;
    let region_last = region_first + region.lines.len() - 1;
    for (i, line) in p.excerpt_lines.iter().enumerate() {
        if i == region_first {
            s.push_str(REGION_START);
            s.push('\n');
        }
        s.push_str(line);
        // The plugin only tracks the cursor line, not the column; end of that
        // line is where a typing user's cursor almost always is.
        if p.excerpt_start + i == p.cursor_line {
            s.push_str(CURSOR);
        }
        s.push('\n');
        if i == region_last {
            s.push_str(REGION_END);
            s.push('\n');
        }
    }
    s.push_str("```\n\n### Response:\n");
    s.push_str(REGION_START);
    s.push('\n');
    s
}

/// Extract the rewritten region lines from the raw completion text.
fn parse_rewrite(output: &str) -> Vec<String> {
    let mut text = output;
    if let Some(idx) = text.find(REGION_START) {
        text = &text[idx + REGION_START.len()..];
    }
    if let Some(idx) = text.find(REGION_END) {
        text = &text[..idx];
    }
    let text = text.replace(CURSOR, "");
    let text = text.strip_prefix('\n').unwrap_or(&text);
    let text = text.strip_suffix('\n').unwrap_or(text);
    text.split('\n').map(str::to_string).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lines(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    fn diff(original: &[&str], rewritten: &[&str]) -> Prediction {
        let original = lines(original);
        let region = EditableRegion { lines: &original, abs_start: 10 };
        region.diff_against(lines(rewritten))
    }

    #[test]
    fn replacement_in_the_middle() {
        let p = diff(&["a", "b", "c"], &["a", "x", "c"]);
        assert!(p.has_edit);
        assert_eq!((p.start_line, p.end_line), (11, 11));
        assert_eq!(p.replacement, lines(&["x"]));
    }

    #[test]
    fn insertion_anchors_on_previous_line() {
        let p = diff(&["a", "b"], &["a", "x", "b"]);
        assert!(p.has_edit);
        assert_eq!((p.start_line, p.end_line), (10, 10));
        assert_eq!(p.replacement, lines(&["a", "x"]));
    }

    #[test]
    fn insertion_at_top_anchors_on_first_line() {
        let p = diff(&["a"], &["x", "a"]);
        assert!(p.has_edit);
        assert_eq!((p.start_line, p.end_line), (10, 10));
        assert_eq!(p.replacement, lines(&["x", "a"]));
    }

    #[test]
    fn deletion() {
        let p = diff(&["a", "b", "c"], &["a", "c"]);
        assert!(p.has_edit);
        assert_eq!((p.start_line, p.end_line), (11, 11));
        assert!(p.replacement.is_empty());
    }

    #[test]
    fn identical_rewrite_is_no_edit() {
        assert!(!diff(&["a", "b"], &["a", "b"]).has_edit);
    }

    #[test]
    fn empty_completion_is_no_edit() {
        assert!(!diff(&["a", "b"], &[""]).has_edit);
    }

    #[test]
    fn parse_strips_markers_and_cursor() {
        let out = format!("\nfoo{CURSOR}\nbar\n{REGION_END} trailing");
        assert_eq!(parse_rewrite(&out), lines(&["foo", "bar"]));
    }
}
