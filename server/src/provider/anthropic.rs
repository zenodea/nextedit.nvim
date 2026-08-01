use anyhow::{bail, Context, Result};
use serde::Deserialize;
use serde_json::json;

use crate::protocol::{PredictParams, Prediction};

use super::{edit_schema, examples, http_client, user_prompt, validate, ModelEdit, SYSTEM_PROMPT};

const DEFAULT_API_URL: &str = "https://api.anthropic.com/v1/messages";
const DEFAULT_MODEL: &str = "claude-haiku-4-5";

pub struct Anthropic {
    client: reqwest::Client,
    api_url: String,
    api_key: String,
    model: String,
}

impl Anthropic {
    pub fn from_env() -> Result<Self> {
        let api_key = std::env::var("NEXTEDIT_API_KEY")
            .or_else(|_| std::env::var("ANTHROPIC_API_KEY"))
            .context("ANTHROPIC_API_KEY is not set")?;
        let api_url = std::env::var("NEXTEDIT_API_URL").unwrap_or_else(|_| DEFAULT_API_URL.into());
        let model = std::env::var("NEXTEDIT_MODEL").unwrap_or_else(|_| DEFAULT_MODEL.into());
        Ok(Self { client: http_client(), api_url, api_key, model })
    }

    pub async fn predict(&self, p: &PredictParams) -> Result<Prediction> {
        let mut messages = Vec::new();
        for (user, assistant) in examples() {
            messages.push(json!({ "role": "user", "content": user }));
            messages.push(json!({ "role": "assistant", "content": assistant }));
        }
        messages.push(json!({ "role": "user", "content": user_prompt(p) }));
        let body = json!({
            "model": self.model,
            "max_tokens": 1024,
            "system": SYSTEM_PROMPT,
            "messages": messages,
            "output_config": { "format": { "type": "json_schema", "schema": edit_schema() } },
        });
        let resp = self
            .client
            .post(&self.api_url)
            .header("x-api-key", &self.api_key)
            .header("anthropic-version", "2023-06-01")
            .json(&body)
            .send()
            .await
            .context("request to Anthropic failed")?;
        let status = resp.status();
        let text = resp.text().await.context("reading Anthropic response failed")?;
        if !status.is_success() {
            bail!("Anthropic API returned {status}: {text}");
        }

        #[derive(Deserialize)]
        struct ApiResponse {
            content: Vec<ContentBlock>,
        }
        #[derive(Deserialize)]
        struct ContentBlock {
            #[serde(rename = "type")]
            kind: String,
            #[serde(default)]
            text: String,
        }

        let api: ApiResponse =
            serde_json::from_str(&text).context("unexpected API response shape")?;
        let json_text = api
            .content
            .iter()
            .find(|b| b.kind == "text")
            .map(|b| b.text.as_str())
            .context("no text block in API response")?;
        let edit: ModelEdit =
            serde_json::from_str(json_text).context("model output did not match schema")?;
        Ok(validate(edit, p))
    }
}
