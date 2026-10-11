//! The yeoman's web: search and fetch through Parallel's keyless MCP server.
//! Search passes through. Fetch opens only links that a search in this same
//! process returned, or that the person wrote themselves: a link the model
//! made up could carry what it has read (mail, memory) out in its path or
//! query, but a link that existed before it read anything carries nothing.
//! Pages can still say anything; what they say is information, not
//! instruction.

use crate::hippo::Hippo;
use serde_json::{Value, json};
use std::collections::HashSet;
use std::sync::Mutex;
use std::time::Duration;
use ureq::Agent;

const PARALLEL: &str = "https://search.parallel.ai/mcp";
const TIMEOUT: Duration = Duration::from_secs(90);

pub struct Web {
    hippo: Hippo,
    agent: Agent,
    /// Links the searches of this process returned, as `key` compares them.
    seen: Mutex<HashSet<String>>,
}

impl Web {
    pub fn new(hippo: Hippo) -> Self {
        let config = Agent::config_builder()
            .timeout_global(Some(TIMEOUT))
            .http_status_as_error(false)
            .build();
        Web {
            hippo,
            agent: Agent::new_with_config(config),
            seen: Mutex::new(HashSet::new()),
        }
    }

    /// One tool call on Parallel's server, as one JSON-RPC post (it answers
    /// plain JSON and needs no session), its text content joined.
    fn call(&self, tool: &str, args: Value) -> Result<String, String> {
        let body = json!({
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": tool, "arguments": args},
        });
        let mut resp = self
            .agent
            .post(PARALLEL)
            .header("Accept", "application/json, text/event-stream")
            .send_json(&body)
            .map_err(|e| format!("parallel: {e}"))?;
        let status = resp.status().as_u16();
        if status >= 400 {
            return Err(format!("parallel: {status}"));
        }
        let reply: Value = resp
            .body_mut()
            .read_json()
            .map_err(|e| format!("parallel: {e}"))?;
        content(&reply)
    }

    pub fn search(&self, objective: &str, queries: &[String]) -> Result<String, String> {
        let text = self.call(
            "web_search",
            json!({"objective": objective, "search_queries": queries}),
        )?;
        if let Ok(found) = serde_json::from_str::<Value>(&text) {
            let mut seen = self.seen.lock().unwrap();
            for url in results(&found) {
                seen.insert(key(url));
            }
        }
        Ok(text)
    }

    pub fn fetch(&self, urls: &[String], objective: Option<&str>) -> Result<String, String> {
        let mut refused = Vec::new();
        for url in urls {
            let seen = self.seen.lock().unwrap().contains(&key(url));
            if !seen && !self.written(url) {
                refused.push(url.as_str());
            }
        }
        if !refused.is_empty() {
            return Ok(format!(
                "Refused, not from a search here or from the person: {}",
                refused.join(", ")
            ));
        }
        let mut args = json!({"urls": urls});
        if let Some(objective) = objective {
            args["objective"] = objective.into();
        }
        self.call("web_fetch", args)
    }

    /// Whether the person wrote this link in a message of theirs.
    fn written(&self, url: &str) -> bool {
        self.hippo
            .search(&literal(url.trim()))
            .is_ok_and(|out| wrote(&out))
    }
}

/// A tool reply's text, or its error.
fn content(reply: &Value) -> Result<String, String> {
    if let Some(msg) = reply["error"]["message"].as_str() {
        return Err(format!("parallel: {msg}"));
    }
    let result = &reply["result"];
    let text = result["content"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|c| c["text"].as_str())
        .collect::<Vec<_>>()
        .join("\n");
    if result["isError"].as_bool().unwrap_or(false) {
        return Err(format!("parallel: {text}"));
    }
    Ok(text)
}

/// The links a search result lists.
fn results(found: &Value) -> impl Iterator<Item = &str> {
    found["results"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|r| r["url"].as_str())
}

/// A link as compared: scheme and host lowercased, no fragment or trailing
/// slash.
fn key(url: &str) -> String {
    let url = url.trim().split('#').next().unwrap_or("");
    let (scheme, rest) = url.split_once("://").unwrap_or(("", url));
    let (host, tail) = rest
        .find(['/', '?'])
        .map_or((rest, ""), |i| rest.split_at(i));
    let (path, query) = tail
        .split_once('?')
        .map_or((tail, None), |(p, q)| (p, Some(q)));
    let mut key = format!(
        "{}://{}{}",
        scheme.to_lowercase(),
        host.to_lowercase(),
        path.trim_end_matches('/')
    );
    if let Some(query) = query {
        key.push('?');
        key.push_str(query);
    }
    key
}

/// A regex matching the text exactly.
fn literal(text: &str) -> String {
    let mut out = String::with_capacity(text.len() * 2);
    for c in text.chars() {
        if r"\.+*?()|[]{}^$#&-~".contains(c) {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

/// Whether a hippo search's lines (`id kind ...`) include one of the person's.
fn wrote(out: &str) -> bool {
    out.lines()
        .filter(|l| l.starts_with(|c: char| c.is_ascii_digit()))
        .any(|l| l.split(' ').nth(1) == Some("user"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_link_compares_without_case_fragment_or_trailing_slash() {
        assert_eq!(
            key(" HTTPS://Example.com/a/b/#top "),
            "https://example.com/a/b"
        );
        assert_eq!(
            key("https://example.com/a?x=1&y=2"),
            "https://example.com/a?x=1&y=2"
        );
        assert_eq!(key("https://example.com/"), "https://example.com");
        assert_eq!(key("https://example.com?q"), "https://example.com?q");
    }

    #[test]
    fn a_literal_escapes_every_regex_special() {
        assert_eq!(
            literal("https://a.b/c?d=1+2&e=(f)"),
            r"https://a\.b/c\?d=1\+2\&e=\(f\)"
        );
    }

    #[test]
    fn only_the_persons_own_lines_count_as_written() {
        assert!(wrote("12 user [dylan] 2026-10-11 12:00: see https://a.b"));
        assert!(!wrote("12 talk [bridge] 2026-10-11 12:00: see https://a.b"));
        assert!(!wrote("no matches\n"));
    }

    #[test]
    fn a_reply_yields_its_text_or_its_error() {
        let ok = json!({"result": {"content": [{"type": "text", "text": "a"}, {"type": "text", "text": "b"}]}});
        assert_eq!(content(&ok).unwrap(), "a\nb");
        let bad = json!({"result": {"isError": true, "content": [{"type": "text", "text": "no"}]}});
        assert_eq!(content(&bad).unwrap_err(), "parallel: no");
        let err = json!({"error": {"code": -32600, "message": "bad"}});
        assert_eq!(content(&err).unwrap_err(), "parallel: bad");
    }

    #[test]
    fn search_results_list_their_links() {
        let found = json!({"results": [{"url": "https://a.b"}, {"title": "none"}]});
        assert_eq!(results(&found).collect::<Vec<_>>(), ["https://a.b"]);
    }
}
