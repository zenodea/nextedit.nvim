use anyhow::{bail, Context, Result};

use crate::protocol::{PredictParams, Prediction};

use super::{chat_body, http_client, parse_chat_content, parse_model_edit, validate};

/// Any OpenAI-compatible chat completions endpoint: OpenAI itself, Mercury
/// (Inception Labs), Ollama, llama.cpp, vLLM, OpenRouter, ...
pub struct OpenAi {
    client: reqwest::Client,
    api_url: String,
    api_key: Option<String>,
    model: String,
}

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
        let mut req = self.client.post(&self.api_url).json(&chat_body(&self.model, p));
        if let Some(key) = &self.api_key {
            req = req.bearer_auth(key);
        }
        let resp = req.send().await.context("request to chat completions endpoint failed")?;
        let status = resp.status();
        let text = resp.text().await.context("reading chat completions response failed")?;
        if !status.is_success() {
            bail!("chat completions endpoint returned {status}: {text}");
        }
        let content = parse_chat_content(&text)?;
        Ok(validate(parse_model_edit(&content)?, p))
    }
}
