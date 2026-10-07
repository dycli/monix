//! Codex: `~/.codex/sessions/YYYY/MM/DD/rollout-…-<session>.jsonl` (moved to
//! `archived_sessions/` when archived), one record per line. Subagent
//! sessions (the approval guardian, say) are other agents' chats.

use super::{Event, Item, call_text, iso, runs_memory, str_at, text_of};
use crate::store::{Kind, Src};
use serde_json::Value;

/// The session id a rollout file name ends in.
pub fn session_of(stem: &str) -> &str {
    stem.get(stem.len().saturating_sub(36)..).unwrap_or(stem)
}

/// Text Codex itself puts into user-role messages.
fn injected(text: &str) -> bool {
    let t = text.trim_start();
    [
        "<environment_context>",
        "<user_instructions>",
        "<recommended_plugins>",
        "<turn_aborted>",
        "<user_shell_command>",
        "# AGENTS.md instructions",
    ]
    .iter()
    .any(|p| t.starts_with(p))
}

/// `line` is the record's byte offset, the id of last resort.
pub fn parse(r: &Value, session: &str, line: u64) -> Vec<Event> {
    let mut out = Vec::new();
    let p = r.get("payload").unwrap_or(&Value::Null);
    match str_at(r, "/type") {
        Some("session_meta") => {
            if p.pointer("/source/subagent").is_some() {
                out.push(Event::Foreign);
            }
            out.push(Event::Info {
                cwd: str_at(p, "/cwd").map(str::to_owned),
                title: str_at(p, "/thread_name").map(str::to_owned),
            });
            return out;
        }
        Some("event_msg") => {
            match str_at(p, "/type") {
                Some("task_complete" | "turn_aborted") => out.push(Event::TurnEnd),
                Some("thread_name_updated") => out.push(Event::Info {
                    cwd: None,
                    title: str_at(p, "/thread_name").map(str::to_owned),
                }),
                _ => {}
            }
            return out;
        }
        Some("response_item") => {}
        Some(
            "turn_context" | "compacted" | "world_state" | "token_usage_record" | "thread_settings",
        ) => return out,
        Some(other) => {
            out.push(Event::Unparsed(format!("record type {other}")));
            return out;
        }
        None => {
            out.push(Event::Unparsed("record without a type".into()));
            return out;
        }
    }
    let Some(date) = str_at(r, "/timestamp").and_then(iso) else {
        out.push(Event::Unparsed("response item without a timestamp".into()));
        return out;
    };
    let src = Src {
        h: "codex".into(),
        s: session.to_owned(),
        e: str_at(p, "/id")
            .map(str::to_owned)
            .unwrap_or_else(|| format!("{session}@{line}")),
    };
    let item = |kind, text: String, opens, call: Option<&str>| Item {
        kind,
        text,
        date,
        src: src.clone(),
        opens,
        call: call.map(str::to_owned),
        memory: false,
    };
    let call_id = str_at(p, "/call_id");
    match str_at(p, "/type") {
        Some("message") => {
            let text = text_of(p.get("content").unwrap_or(&Value::Null));
            match str_at(p, "/role") {
                Some("user") => {
                    // Newer Codex labels each content item; only user.* is
                    // the captain's.
                    let kinds = p
                        .pointer("/internal_chat_message_metadata_passthrough/content_item_kinds")
                        .and_then(Value::as_array);
                    let theirs = match kinds {
                        Some(kinds) => kinds
                            .iter()
                            .all(|k| k.as_str().is_some_and(|k| k.starts_with("user."))),
                        None => !injected(&text),
                    };
                    if theirs && !text.trim().is_empty() {
                        out.push(Event::Item(item(Kind::User, text, true, None)));
                    }
                }
                Some("assistant") => {
                    if !text.trim().is_empty() {
                        out.push(Event::Item(item(Kind::Talk, text, false, None)));
                    }
                }
                Some("developer" | "system") => {}
                other => out.push(Event::Unparsed(format!(
                    "message role {}",
                    other.unwrap_or("missing")
                ))),
            }
        }
        Some(
            ty @ ("function_call" | "custom_tool_call" | "local_shell_call" | "web_search_call"),
        ) => {
            let input = match ty {
                "function_call" => {
                    let raw = str_at(p, "/arguments").unwrap_or("");
                    serde_json::from_str(raw).unwrap_or(Value::String(raw.to_owned()))
                }
                "custom_tool_call" => p.get("input").cloned().unwrap_or(Value::Null),
                _ => p.get("action").cloned().unwrap_or(Value::Null),
            };
            let name = str_at(p, "/name").unwrap_or(match ty {
                "local_shell_call" => "shell",
                "web_search_call" => "web_search",
                _ => "?",
            });
            let mut it = item(Kind::Tool, call_text(name, &input), false, call_id);
            it.memory = runs_memory(&input);
            out.push(Event::Item(it));
        }
        Some("function_call_output" | "custom_tool_call_output" | "local_shell_call_output") => {
            let output = p.get("output").unwrap_or(&Value::Null);
            // function_call_output once held {content, success} as JSON text.
            let text = match output {
                Value::String(s) => serde_json::from_str::<Value>(s)
                    .ok()
                    .and_then(|v| v.get("content").map(text_of))
                    .unwrap_or_else(|| s.clone()),
                other => text_of(other),
            };
            out.push(Event::Item(item(Kind::Echo, text, false, call_id)));
        }
        Some("reasoning" | "compaction" | "ghost_snapshot") => {}
        other => out.push(Event::Unparsed(format!(
            "response item {}",
            other.unwrap_or("without a type")
        ))),
    }
    out
}
