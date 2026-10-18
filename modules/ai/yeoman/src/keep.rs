//! The lease on the assistant's browser. The computer's keeper holds the
//! browser open while a lease runs; the yeoman takes one whenever a reply
//! drives the browser, renews it when the reply ends, and the assistant
//! can hold it indefinitely or let it go on request.

use std::time::Duration;

/// Seconds the browser stays open past its last use.
pub const LEASE: u64 = 1800;

/// Takes or renews the lease; zero seconds means until released.
pub fn hold(url: &str, seconds: u64) -> Result<String, String> {
    post(&format!("{url}/hold?seconds={seconds}"))
}

/// Whether a lease runs, so the browser is open.
pub fn open(url: &str) -> Result<bool, String> {
    agent()
        .get(url)
        .call()
        .and_then(|mut r| r.body_mut().read_to_string())
        .map(|state| state != "closed")
        .map_err(|e| format!("keeper: {e}"))
}

/// Ends the lease now.
pub fn release(url: &str) -> Result<String, String> {
    post(&format!("{url}/release"))
}

fn agent() -> ureq::Agent {
    ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(10)))
        .build()
        .into()
}

fn post(url: &str) -> Result<String, String> {
    agent()
        .post(url)
        .send_empty()
        .and_then(|mut r| r.body_mut().read_to_string())
        .map_err(|e| format!("keeper: {e}"))
}

/// The last computer tool a stream-json event from the model calls, if any.
pub fn computer_call(line: &str) -> Option<String> {
    let ev = serde_json::from_str::<serde_json::Value>(line).ok()?;
    if ev.get("type").and_then(|t| t.as_str()) != Some("assistant") {
        return None;
    }
    ev["message"]["content"]
        .as_array()?
        .iter()
        .filter(|c| c.get("type").and_then(|t| t.as_str()) == Some("tool_use"))
        .filter_map(|c| c.get("name")?.as_str()?.strip_prefix("mcp__computer__"))
        .next_back()
        .map(str::to_owned)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_computer_tool_call_is_seen_in_the_stream() {
        let line = r#"{"type":"assistant","message":{"content":[{"type":"text","text":"hi"},{"type":"tool_use","name":"mcp__computer__browser_navigate","input":{}}]}}"#;
        assert_eq!(computer_call(line).as_deref(), Some("browser_navigate"));
        let other = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__yeoman__web_search","input":{}}]}}"#;
        assert_eq!(computer_call(other), None);
        assert_eq!(computer_call(r#"{"type":"result","result":"done"}"#), None);
        assert_eq!(computer_call("not json"), None);
    }
}
