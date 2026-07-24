use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{bail, Context, Result};
use serde::Deserialize;
use tokio::sync::Mutex;

use crate::protocol::{PredictParams, Prediction};

use super::{chat_body, http_client, parse_chat_content, parse_model_edit, validate};

const TOKEN_URL: &str = "https://api.github.com/copilot_internal/v2/token";
const DEFAULT_API_URL: &str = "https://api.githubcopilot.com/chat/completions";
const DEFAULT_MODEL: &str = "gpt-4.1";

/// GitHub Copilot's chat completions API.
///
/// Auth is two-step: the long-lived GitHub OAuth token (created by signing in
/// with copilot.lua, copilot.vim or VS Code) is exchanged for a short-lived
/// Copilot session token, which we cache until it is about to expire.
pub struct Copilot {
    client: reqwest::Client,
    api_url: String,
    oauth_token: String,
    model: String,
    session: Mutex<Option<Session>>,
}

struct Session {
    token: String,
    expires_at: u64,
}

impl Copilot {
    pub fn from_env() -> Result<Self> {
        let oauth_token = std::env::var("NEXTEDIT_API_KEY")
            .ok()
            .filter(|k| !k.is_empty())
            .or_else(oauth_token_from_config)
            .context(
                "no Copilot credentials: sign in with copilot.lua or copilot.vim \
                 (:Copilot auth), or set NEXTEDIT_API_KEY to a GitHub OAuth token",
            )?;
        let api_url = std::env::var("NEXTEDIT_API_URL").unwrap_or_else(|_| DEFAULT_API_URL.into());
        let model = std::env::var("NEXTEDIT_MODEL").unwrap_or_else(|_| DEFAULT_MODEL.into());
        Ok(Self {
            client: http_client(),
            api_url,
            oauth_token,
            model,
            session: Mutex::new(None),
        })
    }

    /// The cached session token, refreshed via the OAuth token when stale.
    async fn session_token(&self) -> Result<String> {
        let mut session = self.session.lock().await;
        if let Some(s) = session.as_ref() {
            if unix_now() + 60 < s.expires_at {
                return Ok(s.token.clone());
            }
        }

        #[derive(Deserialize)]
        struct TokenResponse {
            token: String,
            expires_at: u64,
        }

        let resp = self
            .client
            .get(TOKEN_URL)
            .header("authorization", format!("token {}", self.oauth_token))
            .header("editor-version", EDITOR_VERSION)
            .header("editor-plugin-version", PLUGIN_VERSION)
            .header("user-agent", PLUGIN_VERSION)
            .send()
            .await
            .context("Copilot token exchange failed")?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .context("reading Copilot token response failed")?;
        if !status.is_success() {
            bail!("Copilot token exchange returned {status}: {text}");
        }
        let tr: TokenResponse =
            serde_json::from_str(&text).context("unexpected Copilot token response shape")?;
        let token = tr.token.clone();
        *session = Some(Session {
            token: tr.token,
            expires_at: tr.expires_at,
        });
        Ok(token)
    }

    pub async fn predict(&self, p: &PredictParams) -> Result<Prediction> {
        let token = self.session_token().await?;
        let resp = self
            .client
            .post(&self.api_url)
            .bearer_auth(token)
            .header("editor-version", EDITOR_VERSION)
            .header("editor-plugin-version", PLUGIN_VERSION)
            .header("user-agent", PLUGIN_VERSION)
            .header("copilot-integration-id", "vscode-chat")
            .json(&chat_body(&self.model, p))
            .send()
            .await
            .context("request to Copilot failed")?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .context("reading Copilot response failed")?;
        if !status.is_success() {
            bail!("Copilot API returned {status}: {text}");
        }
        let content = parse_chat_content(&text)?;
        Ok(validate(parse_model_edit(&content)?, p))
    }
}

const EDITOR_VERSION: &str = "Neovim/0.10.0";
const PLUGIN_VERSION: &str = "nextedit.nvim/0.1.0";

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// The OAuth token that copilot.lua / copilot.vim / VS Code store after sign-in.
fn oauth_token_from_config() -> Option<String> {
    let dir = config_dir()?.join("github-copilot");
    for file in ["apps.json", "hosts.json"] {
        let Ok(text) = std::fs::read_to_string(dir.join(file)) else {
            continue;
        };
        let Ok(json) = serde_json::from_str::<serde_json::Value>(&text) else {
            continue;
        };
        let Some(entries) = json.as_object() else {
            continue;
        };
        for (host, entry) in entries {
            if host.contains("github.com") {
                if let Some(token) = entry.get("oauth_token").and_then(|t| t.as_str()) {
                    return Some(token.to_string());
                }
            }
        }
    }
    None
}

fn config_dir() -> Option<PathBuf> {
    if let Ok(xdg) = std::env::var("XDG_CONFIG_HOME") {
        if !xdg.is_empty() {
            return Some(PathBuf::from(xdg));
        }
    }
    std::env::var("HOME")
        .ok()
        .map(|home| PathBuf::from(home).join(".config"))
}
