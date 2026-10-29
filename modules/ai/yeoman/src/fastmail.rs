//! Fastmail's own MCP server (api.fastmail.com/mcp), as yeoman itself calls
//! it: at start, to learn which tools send, so the model never holds them
//! (see `sends`). The model reaches the rest of the server on its own.
//!
//! Streamable HTTP by hand over ureq, not rmcp's client: every caller here
//! is blocking, and a call is three posts (initialize, initialized, call).

use serde_json::{Value, json};
use std::fs;
use std::time::Duration;
use ureq::Agent;

const URL: &str = "https://api.fastmail.com/mcp";
const TIMEOUT: Duration = Duration::from_secs(60);

pub struct Fastmail {
    token: String,
    agent: Agent,
}

impl Fastmail {
    pub fn new(token: &str) -> Self {
        let config = Agent::config_builder()
            .timeout_global(Some(TIMEOUT))
            .http_status_as_error(false)
            .build();
        Fastmail {
            token: token.trim().to_owned(),
            agent: Agent::new_with_config(config),
        }
    }

    /// The tools the token reaches, as the server lists them.
    pub fn tools(&self) -> Result<Vec<Value>, String> {
        let mut session = Session::open(self)?;
        let v = session.request("tools/list", json!({}))?;
        Ok(v["tools"].as_array().cloned().unwrap_or_default())
    }
}

struct Session<'a> {
    client: &'a Fastmail,
    id: Option<String>,
    next: u64,
}

impl<'a> Session<'a> {
    fn open(client: &'a Fastmail) -> Result<Self, String> {
        let mut s = Session {
            client,
            id: None,
            next: 1,
        };
        s.request(
            "initialize",
            json!({
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "yeoman", "version": env!("CARGO_PKG_VERSION")},
            }),
        )?;
        s.post(&json!({"jsonrpc": "2.0", "method": "notifications/initialized"}))?;
        Ok(s)
    }

    fn request(&mut self, method: &str, params: Value) -> Result<Value, String> {
        let id = self.next;
        self.next += 1;
        let body = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        let text = self.post(&body)?;
        let v = answer(&text, id).ok_or_else(|| format!("fastmail: {method}: no answer"))?;
        if let Some(e) = v.get("error") {
            return Err(format!("fastmail: {method}: {e}"));
        }
        Ok(v["result"].clone())
    }

    fn post(&mut self, body: &Value) -> Result<String, String> {
        let mut req = self
            .client
            .agent
            .post(URL)
            .header("Authorization", &format!("Bearer {}", self.client.token))
            .header("Accept", "application/json, text/event-stream");
        if let Some(id) = &self.id {
            req = req.header("Mcp-Session-Id", id);
        }
        let mut resp = req.send_json(body).map_err(|e| format!("fastmail: {e}"))?;
        if let Some(id) = resp.headers().get("mcp-session-id") {
            self.id = id.to_str().ok().map(str::to_owned);
        }
        let status = resp.status().as_u16();
        let text = resp
            .body_mut()
            .read_to_string()
            .map_err(|e| format!("fastmail: {e}"))?;
        if status >= 400 {
            return Err(format!("fastmail: {status} {}", text.trim()));
        }
        Ok(text)
    }
}

/// The JSON-RPC answer to `id`, from a plain JSON body or an event stream.
fn answer(text: &str, id: u64) -> Option<Value> {
    let is = |v: &Value| v["id"].as_u64() == Some(id);
    if let Ok(v) = serde_json::from_str::<Value>(text) {
        return is(&v).then_some(v);
    }
    text.lines()
        .filter_map(|l| l.strip_prefix("data:"))
        .filter_map(|d| serde_json::from_str::<Value>(d.trim()).ok())
        .find(is)
}

/// The tools that send mail, which the model never holds: what it sends
/// goes through a draft the person approves (pending.rs).
pub fn sends(tools: &[Value]) -> Vec<String> {
    tools
        .iter()
        .filter_map(|t| t["name"].as_str())
        .filter(|n| n.contains("send"))
        .map(str::to_owned)
        .collect()
}

/// The client, when YEOMAN_FASTMAIL names the token file.
pub fn from_env() -> Result<Option<Fastmail>, String> {
    let Some(file) = std::env::var_os("YEOMAN_FASTMAIL") else {
        return Ok(None);
    };
    let token = fs::read_to_string(&file).map_err(|e| format!("fastmail token: {e}"))?;
    Ok(Some(Fastmail::new(&token)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_answer_from_json_or_an_event_stream() {
        let plain = r#"{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}"#;
        assert_eq!(answer(plain, 2).unwrap()["result"]["tools"], json!([]));
        let stream = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{}}\n\n";
        assert!(answer(stream, 3).is_some());
        assert!(answer(stream, 4).is_none());
    }

    #[test]
    fn bars_only_the_sending_tools() {
        let tools =
            json!([{"name": "search_email"}, {"name": "send_email"}, {"name": "draft_email"}]);
        assert_eq!(sends(tools.as_array().unwrap()), ["send_email"]);
    }
}
