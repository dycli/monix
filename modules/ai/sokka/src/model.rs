//! The model behind Sokka, one call per message. Which backend runs it is
//! configuration: the `claude` CLI on a subscription, or any
//! OpenAI-compatible endpoint (local llama.cpp, a hosted API).

use serde_json::{Value, json};
use std::io::{Read, Write};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

/// Seconds one answer may take before the call is abandoned.
const TIMEOUT: Duration = Duration::from_secs(300);

pub trait Model: Send + Sync {
    fn answer(&self, system: &str, prompt: &str) -> Result<String, String>;

    /// Whether answers have tools: web search and Sokka's own.
    fn tools(&self) -> bool {
        false
    }
}

pub fn from_env() -> Result<Box<dyn Model>, String> {
    let var = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
    match var("SOKKA_BACKEND").as_deref().unwrap_or("claude") {
        "claude" => Ok(Box::new(Claude {
            command: var("SOKKA_CLAUDE").unwrap_or_else(|| "claude".into()),
            model: var("SOKKA_MODEL").unwrap_or_else(|| "sonnet".into()),
            effort: var("SOKKA_EFFORT"),
            mcp: var("SOKKA_MCP").map(mcp).transpose()?,
        })),
        "http" => Ok(Box::new(Http {
            url: var("SOKKA_URL").ok_or("SOKKA_URL is not set")?,
            model: var("SOKKA_MODEL").ok_or("SOKKA_MODEL is not set")?,
        })),
        other => Err(format!("Unknown SOKKA_BACKEND {other}.")),
    }
}

/// The `claude` CLI in print mode: no built-in tools, no settings sources
/// (so no hooks), no session saved; only the MCP servers in SOKKA_MCP.
/// Each call stands alone.
pub struct Claude {
    pub command: String,
    pub model: String,
    pub effort: Option<String>,
    /// An MCP config file and the servers it names, all allowed.
    pub mcp: Option<(String, Vec<String>)>,
}

impl Model for Claude {
    fn answer(&self, system: &str, prompt: &str) -> Result<String, String> {
        let mut cmd = Command::new(&self.command);
        cmd.args([
            "-p",
            "--output-format",
            "json",
            "--no-session-persistence",
            "--system-prompt",
            system,
            "--tools",
            "",
            "--strict-mcp-config",
            "--setting-sources",
            "",
            "--model",
            &self.model,
        ]);
        if let Some(effort) = &self.effort {
            cmd.args(["--effort", effort]);
        }
        if let Some((file, servers)) = &self.mcp {
            let allowed: Vec<String> = servers.iter().map(|s| format!("mcp__{s}")).collect();
            cmd.args(["--mcp-config", file, "--allowedTools", &allowed.join(",")]);
        }
        let mut child = cmd
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("{}: {e}", self.command))?;
        let mut stdin = child.stdin.take().unwrap();
        let prompt = prompt.to_owned();
        let writer = thread::spawn(move || stdin.write_all(prompt.as_bytes()));
        let mut stdout = child.stdout.take().unwrap();
        let reader = thread::spawn(move || {
            let mut out = String::new();
            stdout.read_to_string(&mut out).map(|_| out)
        });
        let deadline = Instant::now() + TIMEOUT;
        let status = loop {
            if let Some(status) = child.try_wait().map_err(|e| e.to_string())? {
                break status;
            }
            if Instant::now() > deadline {
                let _ = child.kill();
                let _ = child.wait();
                return Err("claude gave no answer in time".into());
            }
            thread::sleep(Duration::from_millis(100));
        };
        let _ = writer.join();
        let out = reader.join().unwrap().map_err(|e| e.to_string())?;
        let ev: Value = match serde_json::from_str(&out) {
            Ok(ev) => ev,
            Err(_) => {
                let mut err = String::new();
                if let Some(mut e) = child.stderr.take() {
                    let _ = e.read_to_string(&mut err);
                }
                return Err(format!("claude exited {status}: {}", tail(&err)));
            }
        };
        let text = ev.get("result").and_then(Value::as_str).unwrap_or("");
        if ev.get("is_error") == Some(&Value::Bool(true)) {
            return Err(format!("claude: {}", tail(text)));
        }
        Ok(text.trim().to_owned())
    }

    fn tools(&self) -> bool {
        self.mcp.is_some()
    }
}

/// Reads the server names out of an MCP config file.
fn mcp(file: String) -> Result<(String, Vec<String>), String> {
    let text = std::fs::read_to_string(&file).map_err(|e| format!("{file}: {e}"))?;
    let config: Value = serde_json::from_str(&text).map_err(|e| format!("{file}: {e}"))?;
    let servers = config
        .get("mcpServers")
        .and_then(Value::as_object)
        .ok_or_else(|| format!("{file}: no mcpServers"))?
        .keys()
        .cloned()
        .collect();
    Ok((file, servers))
}

/// Any OpenAI-compatible chat completions endpoint over plain HTTP.
pub struct Http {
    pub url: String,
    pub model: String,
}

impl Model for Http {
    fn answer(&self, system: &str, prompt: &str) -> Result<String, String> {
        let url = format!("{}/chat/completions", self.url.trim_end_matches('/'));
        let body = json!({
            "model": self.model,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": prompt},
            ],
        });
        let mut resp = ureq::post(&url)
            .config()
            .http_status_as_error(false)
            .timeout_global(Some(TIMEOUT))
            .build()
            .send_json(&body)
            .map_err(|e| format!("{url}: {e}"))?;
        let status = resp.status().as_u16();
        let v: Value = resp
            .body_mut()
            .read_json()
            .map_err(|e| format!("{url}: {e}"))?;
        if status >= 400 {
            return Err(format!("{url}: {status} {v}"));
        }
        v.pointer("/choices/0/message/content")
            .and_then(Value::as_str)
            .map(|t| t.trim().to_owned())
            .ok_or_else(|| format!("{url}: no content in {v}"))
    }
}

fn tail(s: &str) -> String {
    let s = s.trim();
    let start = s.char_indices().rev().nth(299).map_or(0, |(i, _)| i);
    s[start..].to_owned()
}
