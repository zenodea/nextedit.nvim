use anyhow::{bail, Context, Result};
use serde_json::json;

use crate::protocol::{PredictParams, Prediction};

use super::{chat_body, http_client, parse_chat_content, parse_model_edit, validate};

/// Any OpenAI-compatible chat completions endpoint: OpenAI itself, Mercury
/// (Inception Labs), Ollama, llama.cpp, vLLM, OpenRouter, ...
pub struct OpenAi {
    client: reqwest::Client,
    api_url: String,
    api_key: Option<String>,
    model: String,
    predicted_outputs: bool,
    reasoning_effort: Option<String>,
}

impl OpenAi {
    pub fn from_env(flavor: &str) -> Result<Self> {
        let (default_url, key_var, default_model) = match flavor {
            "mercury" => ("https://api.inceptionlabs.ai/v1", "INCEPTION_API_KEY", "mercury-2"),
            "ollama" => ("http://localhost:11434/v1", "", "qwen2.5-coder:7b"),
            "gemini" => (
                "https://generativelanguage.googleapis.com/v1beta/openai",
                "GEMINI_API_KEY",
                "gemini-2.5-flash",
            ),
            "xai" => ("https://api.x.ai/v1", "XAI_API_KEY", "grok-code-fast-1"),
            "mistral" => ("https://api.mistral.ai/v1", "MISTRAL_API_KEY", "codestral-latest"),
            "openrouter" => (
                "https://openrouter.ai/api/v1",
                "OPENROUTER_API_KEY",
                "google/gemini-2.5-flash-lite",
            ),
            _ => ("https://api.openai.com/v1", "OPENAI_API_KEY", "gpt-5-mini"),
        };
        let base = std::env::var("NEXTEDIT_API_URL").unwrap_or_else(|_| default_url.into());
        let api_url = format!("{}/chat/completions", base.trim_end_matches('/'));
        let api_key = std::env::var("NEXTEDIT_API_KEY")
            .ok()
            .or_else(|| std::env::var(key_var).ok())
            .filter(|k| !k.is_empty());
        if api_key.is_none() && flavor != "ollama" {
            bail!("no API key: set NEXTEDIT_API_KEY (or {key_var}) for provider {flavor}");
        }
        let model = std::env::var("NEXTEDIT_MODEL").unwrap_or_else(|_| default_model.into());
        // Mercury 2 is a reasoning model: left at its default effort it spends
        // hundreds of tokens thinking before emitting the edit, which dominates
        // the round trip (~3.8s vs ~0.5s measured). Edit prediction is a
        // latency-bound, low-difficulty task, so ask for the cheapest tier.
        let reasoning_effort = std::env::var("NEXTEDIT_REASONING_EFFORT")
            .ok()
            .filter(|e| !e.is_empty())
            .or_else(|| (flavor == "mercury").then(|| "instant".to_string()));
        Ok(Self {
            client: http_client(),
            api_url,
            api_key,
            model,
            predicted_outputs: flavor == "openai",
            reasoning_effort,
        })
    }

    async fn post(&self, body: &serde_json::Value) -> Result<(reqwest::StatusCode, String)> {
        let mut req = self.client.post(&self.api_url).json(body);
        if let Some(key) = &self.api_key {
            req = req.bearer_auth(key);
        }
        let resp = req.send().await.context("request to chat completions endpoint failed")?;
        let status = resp.status();
        let text = resp.text().await.context("reading chat completions response failed")?;
        Ok((status, text))
    }

    pub async fn predict(&self, p: &PredictParams) -> Result<Prediction> {
        let mut body = chat_body(&self.model, p);
        let predicted = self.predicted_outputs && add_prediction(&mut body, p);
        if let Some(effort) = &self.reasoning_effort {
            body["reasoning_effort"] = json!(effort);
        }
        let (mut status, mut text) = self.post(&body).await?;
        // Not every model or compatible server accepts these fields (reasoning
        // models reject `prediction`; non-reasoning ones reject
        // `reasoning_effort`); retry once without whichever we added.
        if (predicted || self.reasoning_effort.is_some())
            && status == reqwest::StatusCode::BAD_REQUEST
        {
            if let Some(b) = body.as_object_mut() {
                b.remove("prediction");
                b.remove("reasoning_effort");
            }
            (status, text) = self.post(&body).await?;
        }
        if !status.is_success() {
            bail!("chat completions endpoint returned {status}: {text}");
        }
        let content = parse_chat_content(&text)?;
        Ok(validate(parse_model_edit(&content)?, p))
    }
}

/// Attach an OpenAI predicted-outputs guess: the reply is a JSON edit whose
/// replacement mostly mirrors the lines near the cursor, so seeding it lets
/// the server skip decoding the tokens that match. The window is kept small
/// because rejected prediction tokens are billed at the completion rate.
fn add_prediction(body: &mut serde_json::Value, p: &PredictParams) -> bool {
    const WINDOW: usize = 8;
    let first = p.excerpt_start;
    let last = first + p.excerpt_lines.len().saturating_sub(1);
    if p.excerpt_lines.is_empty() || p.cursor_line < first || p.cursor_line > last {
        return false;
    }
    let start = p.cursor_line.saturating_sub(WINDOW).max(first);
    let end = (p.cursor_line + WINDOW).min(last);
    let guess = json!({
        "has_edit": true,
        "start_line": start,
        "end_line": end,
        "replacement": p.excerpt_lines[start - first..=end - first].join("\n"),
    });
    body["prediction"] = json!({ "type": "content", "content": guess.to_string() });
    true
}
