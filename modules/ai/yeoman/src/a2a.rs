//! A2A, the Agent2Agent protocol (a2a-protocol.org, version 1.0): how the
//! household's assistants and the seat reach one another. Each serves its
//! Agent Card at `/.well-known/agent-card.json` and takes `SendMessage`
//! over JSON-RPC at `/a2a`. A message taken lands in the mailbox the
//! household already uses (house.rs), so what happens to it after is
//! unchanged.
//!
//! Peers listen on loopback and share one bearer token, kept in the
//! household directory: the same trust as the mailboxes, which every member
//! can already write. Only `SendMessage` is served; the answer comes back
//! later as a message of its own, as a note does.

use serde_json::{Value, json};
use std::env;
use std::fs;
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// Where the JSON-RPC endpoint is, under each peer's address.
pub const PATH: &str = "/a2a";
/// Where the Agent Card is.
pub const CARD: &str = "/.well-known/agent-card.json";
const VERSION: &str = "1.0";
/// The most a message may carry, in bytes.
pub const MAX: usize = 64 * 1024;

/// The peers reached over A2A, from YEOMAN_A2A (`unit=url,...`); `seat`
/// names the seat's own chat.
pub fn peers() -> Vec<(String, String)> {
    env::var("YEOMAN_A2A")
        .unwrap_or_default()
        .split(',')
        .filter_map(|p| {
            let (unit, url) = p.trim().split_once('=')?;
            Some((
                unit.trim().to_owned(),
                url.trim().trim_end_matches('/').to_owned(),
            ))
        })
        .collect()
}

/// The address of peer `unit`, if it is reached over A2A.
pub fn url(unit: &str) -> Option<String> {
    peers()
        .into_iter()
        .find(|(u, _)| u == unit)
        .map(|(_, url)| url)
}

/// The household's token, made by whichever member needs it first.
pub fn token(house: &Path) -> Result<String, String> {
    let path = house.join("a2a.token");
    if let Ok(t) = fs::read_to_string(&path)
        && !t.trim().is_empty()
    {
        return Ok(t.trim().to_owned());
    }
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes).map_err(|e| format!("a2a token: {e}"))?;
    let made: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    // Written aside and linked into place, so two members making one at
    // once agree on the first.
    let tmp = house.join(format!(".a2a.token.{}", std::process::id()));
    fs::write(&tmp, &made).map_err(|e| format!("a2a token: {e}"))?;
    crate::house::shared(&tmp).map_err(|e| format!("a2a token: {e}"))?;
    let linked = fs::hard_link(&tmp, &path);
    let _ = fs::remove_file(&tmp);
    match linked {
        Ok(()) => Ok(made),
        Err(_) => fs::read_to_string(&path)
            .map(|t| t.trim().to_owned())
            .map_err(|e| format!("a2a token: {e}")),
    }
}

/// This assistant's Agent Card.
pub fn card(name: &str, person: &str, url: &str) -> Value {
    json!({
        "name": name,
        "description": format!("{person}'s assistant in the household."),
        "version": env!("CARGO_PKG_VERSION"),
        "supportedInterfaces": [{
            "url": format!("{url}{PATH}"),
            "protocolBinding": "JSONRPC",
            "protocolVersion": VERSION,
        }],
        "capabilities": { "streaming": false, "pushNotifications": false },
        "securitySchemes": { "household": { "httpAuthSecurityScheme": { "scheme": "Bearer" } } },
        "securityRequirements": [{ "schemes": { "household": { "list": [] } } }],
        "defaultInputModes": ["text/plain"],
        "defaultOutputModes": ["text/plain"],
        "skills": [{
            "id": "message",
            "name": "Message",
            "description": format!("Takes a message for {name}, who answers in a message of its own."),
            "tags": ["household"],
        }],
    })
}

/// Sends `text` from `from` (a unit, or `seat`) to the peer at `url`.
pub fn send(url: &str, token: &str, from: &str, text: &str) -> Result<(), String> {
    let ns = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos());
    let body = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "SendMessage",
        "params": {
            "message": {
                "messageId": format!("{from}-{ns}"),
                "role": "ROLE_USER",
                "parts": [{ "text": text }],
                "metadata": { "from": from },
            },
        },
    });
    let agent = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(20)))
        .http_status_as_error(false)
        .build()
        .new_agent();
    let mut r = agent
        .post(&format!("{url}{PATH}"))
        .header("Authorization", &format!("Bearer {token}"))
        .header("A2A-Version", VERSION)
        .send_json(&body)
        .map_err(|e| format!("{url}: {e}"))?;
    let status = r.status();
    let answer: Value = r
        .body_mut()
        .read_json()
        .map_err(|e| format!("{url}: {status}: {e}"))?;
    match answer.get("error") {
        Some(e) => Err(format!(
            "{url}: {}",
            e["message"].as_str().unwrap_or("refused")
        )),
        None if status.is_success() => Ok(()),
        None => Err(format!("{url}: {status}")),
    }
}

/// What a request asks: a message's sender and words, or the JSON-RPC
/// error to answer with.
pub fn take(request: &Value) -> Result<(String, String), Value> {
    let id = request.get("id").cloned().unwrap_or(Value::Null);
    let error = |code: i64, message: &str| json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message } });
    match request["method"].as_str() {
        Some("SendMessage") => {}
        // UnsupportedOperationError: the rest of A2A is not served here.
        Some(_) => return Err(error(-32004, "Only SendMessage is served here.")),
        None => return Err(error(-32600, "Not a JSON-RPC request.")),
    }
    let message = &request["params"]["message"];
    let text: String = message["parts"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|p| p["text"].as_str())
        .collect::<Vec<_>>()
        .join("\n");
    let from = message["metadata"]["from"].as_str().unwrap_or_default();
    if text.trim().is_empty() || from.is_empty() {
        return Err(error(-32602, "A message needs text and metadata.from."));
    }
    if text.len() > MAX {
        return Err(error(-32602, "The message is too long."));
    }
    Ok((from.to_owned(), text))
}

/// The answer to a message taken: a message saying it was delivered.
pub fn taken(request: &Value, name: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": request.get("id").cloned().unwrap_or(Value::Null),
        "result": {
            "message": {
                "messageId": format!("{}-taken", request["params"]["message"]["messageId"].as_str().unwrap_or("message")),
                "role": "ROLE_AGENT",
                "parts": [{ "text": format!("Delivered to {name}, who answers in a message of its own.") }],
            },
        },
    })
}

/// An error JSON-RPC answer to a request that couldn't be delivered.
pub fn failed(request: &Value, message: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": request.get("id").cloned().unwrap_or(Value::Null),
        "error": { "code": -32603, "message": message },
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn takes_a_message_and_refuses_the_rest() {
        let ok = json!({"jsonrpc": "2.0", "id": 7, "method": "SendMessage", "params": {"message": {
            "messageId": "m", "role": "ROLE_USER", "parts": [{"text": "hi"}], "metadata": {"from": "suki"}}}});
        assert_eq!(take(&ok).unwrap(), ("suki".into(), "hi".into()));
        assert_eq!(taken(&ok, "Bridge")["id"], 7);
        let other = json!({"jsonrpc": "2.0", "id": 1, "method": "GetTask", "params": {}});
        assert_eq!(take(&other).unwrap_err()["error"]["code"], -32004);
        let anon = json!({"jsonrpc": "2.0", "id": 1, "method": "SendMessage", "params": {"message": {"parts": [{"text": "hi"}]}}});
        assert!(take(&anon).is_err());
    }

    #[test]
    fn token_is_made_once() {
        let dir = std::env::temp_dir().join(format!("a2a-token-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let a = token(&dir).unwrap();
        assert_eq!(a.len(), 64);
        assert_eq!(token(&dir).unwrap(), a);
        fs::remove_dir_all(&dir).unwrap();
    }
}
