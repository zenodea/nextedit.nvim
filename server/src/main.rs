mod protocol;
mod provider;

use std::sync::Arc;

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::Mutex;

use protocol::{Request, Response};
use provider::Anthropic;

#[tokio::main]
async fn main() {
    let provider = Arc::new(match Anthropic::from_env() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("nextedit-server: {e}");
            std::process::exit(1);
        }
    });
    let stdout = Arc::new(Mutex::new(tokio::io::stdout()));
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    let mut in_flight: Option<tokio::task::JoinHandle<()>> = None;

    while let Ok(Some(line)) = lines.next_line().await {
        if line.trim().is_empty() {
            continue;
        }
        let req: Request = match serde_json::from_str(&line) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("nextedit-server: bad request: {e}");
                continue;
            }
        };
        // A new request supersedes whatever we were predicting before.
        if let Some(task) = in_flight.take() {
            task.abort();
        }
        let (provider, stdout) = (provider.clone(), stdout.clone());
        in_flight = Some(tokio::spawn(async move {
            let response = match provider.predict(&req.params).await {
                Ok(prediction) => Response { id: req.id, result: Some(prediction), error: None },
                Err(e) => Response { id: req.id, result: None, error: Some(format!("{e:#}")) },
            };
            let mut json = serde_json::to_string(&response).expect("response serializes");
            json.push('\n');
            let mut out = stdout.lock().await;
            let _ = out.write_all(json.as_bytes()).await;
            let _ = out.flush().await;
        }));
    }
}
