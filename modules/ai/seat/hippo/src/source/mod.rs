//! Harness transcripts turned into events. Each parser reads one raw entry
//! and says what it means for the log; the watcher decides when to log.

pub mod claude;
pub mod codex;
pub mod opencode;

use crate::store::{Kind, Src};
use chrono::{DateTime, Local};
use serde_json::Value;

/// Max size of a tool result in the log, in characters, head and tail kept.
pub const CAP: usize = 30_000;

#[derive(Clone, Debug)]
pub struct Item {
    pub kind: Kind,
    pub text: String,
    pub date: DateTime<Local>,
    pub src: Src,
    /// The captain's prompt that opens a turn (a `user` message typed while
    /// a turn runs does not).
    pub opens: bool,
    /// Tool call id, on a `tool`; the call answered, on an `echo`.
    pub call: Option<String>,
    /// A `tool` that runs hippo or memo: its result is left out.
    pub memory: bool,
}

#[derive(Clone, Debug)]
pub enum Event {
    Item(Item),
    /// The agent finished answering.
    TurnEnd,
    /// Session facts: working directory, title.
    Info {
        cwd: Option<String>,
        title: Option<String>,
    },
    /// The whole session is not the seat's own chat (a subagent).
    Foreign,
    /// An entry that could not be understood: reported, never guessed.
    Unparsed(String),
}

pub fn str_at<'a>(v: &'a Value, pointer: &str) -> Option<&'a str> {
    v.pointer(pointer).and_then(Value::as_str)
}

pub fn iso(s: &str) -> Option<DateTime<Local>> {
    DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|d| d.with_timezone(&Local))
}

/// Text of a content value: a string, or an array of text and image blocks.
pub fn text_of(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Array(items) => items
            .iter()
            .filter_map(|item| match item {
                Value::String(s) => Some(s.clone()),
                _ => match str_at(item, "/type") {
                    Some("image" | "input_image") => Some("[image]".to_owned()),
                    Some("document") => Some("[document]".to_owned()),
                    _ => item
                        .get("text")
                        .or_else(|| item.get("output"))
                        .and_then(Value::as_str)
                        .map(str::to_owned),
                },
            })
            .collect::<Vec<_>>()
            .join("\n"),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

/// A tool call as its name and JSON input.
pub fn call_text(name: &str, input: &Value) -> String {
    match input {
        Value::Null => name.to_owned(),
        Value::String(raw) => format!("{name} {raw}"),
        other => format!("{name} {other}"),
    }
}

/// Caps a tool result at `CAP` characters, keeping head and tail and saying
/// what was cut.
pub fn cap(text: String) -> String {
    let chars = text.chars().count();
    if chars <= CAP {
        return text;
    }
    let half = CAP / 2;
    let head: String = text.chars().take(half).collect();
    let tail: String = text.chars().skip(chars - half).collect();
    format!(
        "{head}\n[… {} of {chars} characters cut by hippo …]\n{tail}",
        chars - CAP
    )
}

/// Whether a tool call runs `hippo` or `memo`: its output would make the
/// memory summarize itself.
pub fn runs_memory(input: &Value) -> bool {
    match input {
        Value::String(raw) => match serde_json::from_str::<Value>(raw) {
            Ok(v) => is_memory(&command_of(&v)),
            // Codex's exec tool takes a script: tools.exec_command({cmd: "…"}).
            Err(_) => {
                let mut cmds = CMD
                    .captures_iter(raw)
                    .map(|c| c[1].replace("\\\"", "\""))
                    .peekable();
                if cmds.peek().is_none() {
                    is_memory(raw)
                } else {
                    cmds.any(|c| is_memory(&c))
                }
            }
        },
        other => is_memory(&command_of(other)),
    }
}

static CMD: std::sync::LazyLock<regex::Regex> = std::sync::LazyLock::new(|| {
    regex::Regex::new(r#""?(?:cmd|command)"?\s*:\s*"((?:[^"\\]|\\.)*)""#).unwrap()
});

fn is_memory(command: &str) -> bool {
    command
        .split(['\n', ';', '&', '|', '(', ')', '`'])
        .flat_map(|seg| seg.split("$("))
        .any(|seg| {
            let mut words = seg
                .split_whitespace()
                .skip_while(|w| w.contains('=') && !w.starts_with('-'));
            let first = words.next().unwrap_or("");
            let first = first.rsplit('/').next().unwrap_or(first);
            matches!(first, "hippo" | "memo")
        })
}

fn command_of(v: &Value) -> String {
    match v
        .get("command")
        .or_else(|| v.get("cmd"))
        .or_else(|| v.get("input"))
    {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Array(parts)) => {
            let parts: Vec<&str> = parts.iter().filter_map(Value::as_str).collect();
            // ["bash", "-lc", script] runs the script.
            match parts.as_slice() {
                [_, flag, script] if flag.ends_with('c') && flag.starts_with('-') => {
                    (*script).to_owned()
                }
                _ => parts.join(" "),
            }
        }
        _ => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn memory_commands() {
        for yes in [
            json!({"command": "hippo view"}),
            json!({"command": "cd x && memo note \"hi\""}),
            json!({"command": "echo $(hippo date 3)"}),
            json!({"command": ["bash", "-lc", "memo wake"]}),
            json!("{\"cmd\":\"/run/current-system/sw/bin/hippo zoom 0 1\"}"),
            json!("const r = await tools.exec_command({cmd:\"memo wake\",\"workdir\":\"/x\"});"),
        ] {
            assert!(runs_memory(&yes), "{yes}");
        }
        for no in [
            json!({"command": "git commit -m 'drop memo chats'"}),
            json!({"command": "cd modules/ai/seat/memo-cli && cargo test"}),
            json!({"command": "ls hippo/"}),
            json!({"file_path": "/x/hippo"}),
            json!("const r = await tools.exec_command({\"cmd\":\"ls memo\"});"),
        ] {
            assert!(!runs_memory(&no), "{no}");
        }
    }

    #[test]
    fn caps_head_and_tail() {
        let long = "a".repeat(CAP) + &"b".repeat(100);
        let out = cap(long);
        assert!(out.starts_with("aaa") && out.ends_with("bbb"));
        assert!(out.contains("100 of 30100 characters cut"));
        assert_eq!(cap("short".into()), "short");
    }
}
