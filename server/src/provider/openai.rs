use anyhow::{bail, Context, Result};
use serde::Deserialize;
use serde_json::json;

use crate::protocol::{PredictParams, Prediction};

use super::{http_client, parse_model_edit, user_prompt, validate, SYSTEM_PROMPT};

/// Any OpenAI-compatible chat completions endpoint: OpenAI itself, Mercury
/// (Inception Labs), Ollama, llama.cpp, vLLM, OpenRouter, ...
pub struct OpenAi {
    client: reqwest::Client,
    api_url: String,
    api_key: Option<String>,
    model: String,
}

// The JSON instructions live in the prompt rather than response_format because
// not every compatible server supports json_schema, and several reject unknown
// response_format values outright.
const FORMAT_INSTRUCTIONS: &str = "\n\nRespond with only a JSON object shaped as \
{\"has_edit\": boolean, \"start_line\": integer, \"end_line\": integer, \"replacement\": string} \
where replacement is the full new text for the replaced lines, newline-separated, \
and an empty string deletes them. No prose, no code fences.";

impl OpenAi {
    pub fn from_env(flavor: &str) -> Result<Self> {
        let (default_url, key_var, default_model) = match flavor {
            "mercury" => ("https://api.inceptionlabs.ai/v1", "INCEPTION_API_KEY", "mercury-coder"),
            "ollama" => ("http://localhost:11434/v1", "", "qwen2.5-coder:7b"),
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
        Ok(Self { client: http_client(), api_url, api_key, model })
    }

    pub async fn predict(&self, p: &PredictParams) -> Result<Prediction> {
        // Only universally supported fields: reasoning-model endpoints reject
        // max_tokens and non-default temperature.
        let body = json!({
            "model": self.model,
            "messages": [
                { "role": "system", "content": format!("{SYSTEM_PROMPT}{FORMAT_INSTRUCTIONS}") },
                { "role": "user", "content": user_prompt(p) },
            ],
        });
        let mut req = self.client.post(&self.api_url).json(&body);
        if let Some(key) = &self.api_key {
            req = req.bearer_auth(key);
        }
        let resp = req.send().await.context("request to chat completions endpoint failed")?;
        let status = resp.status();
        let text = resp.text().await.context("reading chat completions response failed")?;
        if !status.is_success() {
            bail!("chat completions endpoint returned {status}: {text}");
        }

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

        let api: ApiResponse =
            serde_json::from_str(&text).context("unexpected API response shape")?;
        let content = api
            .choices
            .first()
            .map(|c| c.message.content.as_str())
            .context("no choices in API response")?;
        Ok(validate(parse_model_edit(content)?, p))
    }
}
