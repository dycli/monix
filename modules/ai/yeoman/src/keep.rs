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

/// Ends the lease now.
pub fn release(url: &str) -> Result<String, String> {
    post(&format!("{url}/release"))
}

fn post(url: &str) -> Result<String, String> {
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(10)))
        .build()
        .into();
    agent
        .post(url)
        .send_empty()
        .and_then(|mut r| r.body_mut().read_to_string())
        .map_err(|e| format!("keeper: {e}"))
}

/// Whether a stream-json event from the model calls a computer tool.
pub fn uses_computer(line: &str) -> bool {
    let Ok(ev) = serde_json::from_str::<serde_json::Value>(line) else {
        return false;
    };
    ev.get("type").and_then(|t| t.as_str()) == Some("assistant")
        && ev["message"]["content"]
            .as_array()
            .into_iter()
            .flatten()
            .any(|c| {
                c.get("type").and_then(|t| t.as_str()) == Some("tool_use")
                    && c.get("name")
                        .and_then(|n| n.as_str())
                        .is_some_and(|n| n.starts_with("mcp__computer__"))
            })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_computer_tool_call_is_seen_in_the_stream() {
        let line = r#"{"type":"assistant","message":{"content":[{"type":"text","text":"hi"},{"type":"tool_use","name":"mcp__computer__browser_navigate","input":{}}]}}"#;
        assert!(uses_computer(line));
        let other = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__yeoman__web_search","input":{}}]}}"#;
        assert!(!uses_computer(other));
        assert!(!uses_computer(r#"{"type":"result","result":"done"}"#));
        assert!(!uses_computer("not json"));
    }
}
