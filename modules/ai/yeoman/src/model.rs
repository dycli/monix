//! The model behind the yeoman, one call per message. Which backend runs it is
//! configuration: the `claude` CLI on a subscription, or any
//! OpenAI-compatible endpoint (local llama.cpp, a hosted API).

use base64::Engine;
use base64::engine::general_purpose::STANDARD as B64;
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};

use crate::keep;
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant};

/// Seconds one answer may take before the call is abandoned.
const TIMEOUT: Duration = Duration::from_secs(300);

/// A file sent with a message, in a form models read directly.
pub enum Attachment {
    Image { mime: &'static str, data: Vec<u8> },
    Pdf(Vec<u8>),
}

pub trait Model: Send + Sync {
    /// Answers a prompt. With `acts` false the tools that change anything
    /// (reminders, lists, the mailbox, the calendar, pictures, fetching a
    /// page) are withheld: the turn was started by an alert or someone
    /// else's message, not by the person. `memory` is the hippo view, sent
    /// ahead of everything else in the message so its settled part can be
    /// read from the prompt cache on the next call.
    fn answer(
        &self,
        system: &str,
        memory: &str,
        prompt: &str,
        files: &[Attachment],
        run: Run,
    ) -> Result<String, String>;

    /// Whether answers have tools: web search and the yeoman's own.
    fn tools(&self) -> bool {
        false
    }
}

pub fn from_env() -> Result<Box<dyn Model>, String> {
    let var = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
    match var("YEOMAN_BACKEND").as_deref().unwrap_or("claude") {
        "claude" => Ok(Box::new(Claude {
            command: var("YEOMAN_CLAUDE").unwrap_or_else(|| "claude".into()),
            model: var("YEOMAN_MODEL").unwrap_or_else(|| "sonnet".into()),
            effort: var("YEOMAN_EFFORT"),
            mcp: var("YEOMAN_MCP").map(mcp).transpose()?,
            keep: var("YEOMAN_KEEP"),
        })),
        "http" => Ok(Box::new(Http {
            url: var("YEOMAN_URL").ok_or("YEOMAN_URL is not set")?,
            model: var("YEOMAN_MODEL").ok_or("YEOMAN_MODEL is not set")?,
        })),
        other => Err(format!("Unknown YEOMAN_BACKEND {other}.")),
    }
}

/// The `claude` CLI in print mode: no built-in tools, no settings sources
/// (so no hooks), no session saved; only the MCP servers in YEOMAN_MCP.
/// How a turn runs. A task has no clock on it and can be stopped.
#[derive(Clone, Default)]
pub struct Run {
    pub acts: bool,
    pub stop: Option<Arc<AtomicBool>>,
}

/// Each call stands alone.
pub struct Claude {
    pub command: String,
    pub model: String,
    pub effort: Option<String>,
    /// An MCP config file and the servers it names, all allowed.
    pub mcp: Option<(String, Vec<String>)>,
    /// The computer's keeper, when there is a computer: the browser is
    /// leased for a while whenever a reply drives it.
    pub keep: Option<String>,
}

/// The tools that act on the world, by MCP name.
const ACTS: &str = "mcp__yeoman__remind,mcp__yeoman__cancel_reminder,mcp__yeoman__list_add,\
mcp__yeoman__share_list,mcp__yeoman__list_remove,mcp__yeoman__tell,mcp__yeoman__draft_mail,mcp__yeoman__add_event,\
mcp__yeoman__change_event,mcp__yeoman__cancel_event,mcp__image__make_image,mcp__yeoman__web_fetch,\
mcp__computer,mcp__home,mcp__yeoman__media_request,mcp__yeoman__task";

impl Model for Claude {
    fn answer(
        &self,
        system: &str,
        memory: &str,
        prompt: &str,
        files: &[Attachment],
        run: Run,
    ) -> Result<String, String> {
        let mut cmd = Command::new(&self.command);
        // One-hour cache entries, pinned rather than left to Claude Code's
        // default: the memory's mark must match the lifetime of Claude
        // Code's own marks, or the API refuses the call.
        cmd.env("ENABLE_PROMPT_CACHING_1H", "1");
        // Stream-json is the only way to hand the CLI images and PDFs; it
        // needs stream-json out, which ends with the result event.
        cmd.args([
            "-p",
            "--input-format",
            "stream-json",
            "--output-format",
            "stream-json",
            "--verbose",
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
            if !run.acts {
                cmd.args(["--disallowedTools", ACTS]);
            }
        }
        let mut child = cmd
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("{}: {e}", self.command))?;
        let mut content = cached(memory);
        content.extend(files.iter().map(|f| match f {
            Attachment::Image { mime, data } => json!({"type": "image",
                    "source": {"type": "base64", "media_type": mime, "data": B64.encode(data)}}),
            Attachment::Pdf(data) => json!({"type": "document",
                    "source": {"type": "base64", "media_type": "application/pdf",
                               "data": B64.encode(data)}}),
        }));
        content.push(json!({"type": "text", "text": prompt}));
        let line = json!({"type": "user", "message": {"role": "user", "content": content}});
        let mut stdin = child.stdin.take().unwrap();
        let line = format!("{line}\n");
        let writer = thread::spawn(move || stdin.write_all(line.as_bytes()));
        let stdout = child.stdout.take().unwrap();
        let keep = self.keep.clone();
        let reader = thread::spawn(move || -> std::io::Result<(String, bool)> {
            let mut out = String::new();
            let mut used = false;
            for line in BufReader::new(stdout).lines() {
                let line = line?;
                // The browser is leased the moment the reply first drives
                // it, before the reply's own session ends and closes it.
                if let (false, Some(url)) = (used, &keep)
                    && keep::uses_computer(&line)
                {
                    used = true;
                    if let Err(e) = keep::hold(url, keep::LEASE) {
                        eprintln!("yeoman: {e}");
                    }
                }
                out.push_str(&line);
                out.push('\n');
            }
            Ok((out, used))
        });
        let errors = drain(child.stderr.take().unwrap());
        let deadline = run.stop.is_none().then(|| Instant::now() + TIMEOUT);
        let status = loop {
            if let Some(status) = child.try_wait().map_err(|e| e.to_string())? {
                break status;
            }
            let stopped = run.stop.as_ref().is_some_and(|s| s.load(Ordering::Relaxed));
            if stopped || deadline.is_some_and(|d| Instant::now() > d) {
                let _ = child.kill();
                let _ = child.wait();
                return Err(if stopped {
                    "stopped".into()
                } else {
                    "claude gave no answer in time".into()
                });
            }
            thread::sleep(Duration::from_millis(100));
        };
        let _ = writer.join();
        let (out, used) = reader.join().unwrap().map_err(|e| e.to_string())?;
        if let (true, Some(url)) = (used, &self.keep)
            && let Err(e) = keep::hold(url, keep::LEASE)
        {
            eprintln!("yeoman: {e}");
        }
        let result = out
            .lines()
            .filter_map(|l| serde_json::from_str::<Value>(l).ok())
            .find(|ev| ev.get("type").and_then(Value::as_str) == Some("result"));
        let ev = match result {
            Some(ev) => ev,
            None => {
                let err = errors.join().unwrap_or_default();
                return Err(format!("claude exited {status}: {}", tail(&err)));
            }
        };
        // One journal line per model per call, where `usage` counts each
        // assistant's share of the subscriptions.
        let models = ev.get("modelUsage").and_then(Value::as_object);
        for (model, u) in models.into_iter().flatten() {
            let n = |k: &str| u.get(k).and_then(Value::as_u64).unwrap_or(0);
            eprintln!(
                "yeoman: tokens model={model} input={} cache_read={} cache_write={} output={}",
                n("inputTokens"),
                n("cacheReadInputTokens"),
                n("cacheCreationInputTokens"),
                n("outputTokens"),
            );
        }
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

/// Lines per content block of the memory. The API looks back up to 20
/// blocks from a cache mark for an entry an earlier call wrote, so the next
/// call, its memory grown by a few lines, still finds this one's. The same
/// scheme as hippo's compactor.
const BLOCK: usize = 4;

/// What hippo shows for a line the compactor has not written yet.
const PLACEHOLDER: &str = "(not summarized yet: zoom it)";

/// The memory as content blocks of `BLOCK` lines, the last whole block of
/// its settled part marked for the cache. Lines from the first one not yet
/// summarized on, and hippo's note after `</chat>`, change before the next
/// call, so the mark stays ahead of them. The API allows four marks and
/// Claude Code uses three.
fn cached(memory: &str) -> Vec<Value> {
    let lines: Vec<&str> = memory.split_inclusive('\n').collect();
    let settled = lines
        .iter()
        .position(|l| l.contains(PLACEHOLDER) || l.starts_with("</chat>"))
        .unwrap_or(lines.len());
    let mark = settled / BLOCK;
    lines
        .chunks(BLOCK)
        .enumerate()
        .map(|(n, chunk)| {
            let text = chunk.concat();
            if n + 1 == mark {
                json!({"type": "text", "text": text,
                    "cache_control": {"type": "ephemeral", "ttl": "1h"}})
            } else {
                json!({"type": "text", "text": text})
            }
        })
        .collect()
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
    fn answer(
        &self,
        system: &str,
        memory: &str,
        prompt: &str,
        files: &[Attachment],
        _run: Run,
    ) -> Result<String, String> {
        let url = format!("{}/chat/completions", self.url.trim_end_matches('/'));
        let mut content = vec![json!({"type": "text", "text": memory})];
        for f in files {
            match f {
                Attachment::Image { mime, data } => content.push(json!({"type": "image_url",
                    "image_url": {"url": format!("data:{mime};base64,{}", B64.encode(data))}})),
                Attachment::Pdf(_) => return Err("this model can't read PDFs".into()),
            }
        }
        content.push(json!({"type": "text", "text": prompt}));
        let body = json!({
            "model": self.model,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": content},
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

/// Reads a pipe to its end on its own thread, so a chatty child never
/// blocks on a full pipe, and keeps the last few kilobytes.
fn drain(mut pipe: impl Read + Send + 'static) -> thread::JoinHandle<String> {
    thread::spawn(move || {
        let (mut kept, mut chunk) = (Vec::new(), [0u8; 4096]);
        while let Ok(n @ 1..) = pipe.read(&mut chunk) {
            kept.extend_from_slice(&chunk[..n]);
            let over = kept.len().saturating_sub(8192);
            kept.drain(..over);
        }
        String::from_utf8_lossy(&kept).into_owned()
    })
}

fn tail(s: &str) -> String {
    let s = s.trim();
    let start = s.char_indices().rev().nth(299).map_or(0, |(i, _)| i);
    s[start..].to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn marks(blocks: &[Value]) -> Vec<usize> {
        (0..blocks.len())
            .filter(|&k| blocks[k].get("cache_control").is_some())
            .collect()
    }

    #[test]
    fn memory_rejoins_and_marks_its_settled_part() {
        let lines: String = (0..10).map(|i| format!("{i}+1|line {i}\n")).collect();
        let memory =
            format!("<chat>\n{lines}</chat>\n3 recent lines are not summarized yet: zoom them.\n");
        let blocks = cached(&memory);
        let text: String = blocks.iter().map(|b| b["text"].as_str().unwrap()).collect();
        assert_eq!(text, memory);
        // Eleven lines before </chat>: two whole blocks, the second marked.
        assert_eq!(marks(&blocks), vec![1]);
        assert_eq!(blocks[1]["cache_control"]["ttl"], "1h");
    }

    #[test]
    fn mark_stays_ahead_of_unsummarized_lines() {
        let memory = format!(
            "<chat>\n0+4|a\n4+1|b\n5+1|c\n6+1|d\n7+1|e\n8+1|{PLACEHOLDER}\n9+1|{PLACEHOLDER}\n</chat>\n"
        );
        let blocks = cached(&memory);
        // Six settled lines: one whole block, marked.
        assert_eq!(marks(&blocks), vec![0]);
        assert!(!blocks[0]["text"].as_str().unwrap().contains(PLACEHOLDER));
    }

    #[test]
    fn short_memory_has_no_mark() {
        assert!(marks(&cached("<chat>\n0+1|a\n</chat>\n")).is_empty());
    }
}
