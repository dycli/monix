//! Claude Code: `~/.claude/projects/<project>/<session>.jsonl`, one entry
//! per line, one content block per assistant entry. Subagents write their
//! own files one directory deeper; those are never read.

use super::{Event, Item, call_text, iso, runs_memory, str_at, text_of};
use crate::store::{Kind, Src};
use serde_json::Value;

/// Top-level entry types that carry nothing for the log.
const IGNORED: &[&str] = &[
    "system",
    "queue-operation",
    "last-prompt",
    "file-history-snapshot",
    "file-history-delta",
    "cost-state",
    "atis-latch",
    "progress",
    "summary",
    "tag",
    "agent-name",
    "pr-link",
    "mode",
    "permission-mode",
    "bridge-session",
];

/// Text the harness writes into user entries on its own.
fn injected(text: &str) -> bool {
    let t = text.trim_start();
    [
        "<command-name>",
        "<command-message>",
        "<command-args>",
        "<local-command-",
        "<system-reminder>",
        "Caveat: The messages below were generated",
    ]
    .iter()
    .any(|p| t.starts_with(p))
}

fn interrupted(text: &str) -> bool {
    text.starts_with("[Request interrupted by user")
}

pub fn parse(r: &Value, session: &str) -> Vec<Event> {
    let mut out = Vec::new();
    let Some(ty) = str_at(r, "/type") else {
        out.push(Event::Unparsed("entry without a type".into()));
        return out;
    };
    let flag = |k: &str| r.get(k) == Some(&Value::Bool(true));
    if flag("isSidechain") {
        return out;
    }
    if ty == "custom-title" || ty == "ai-title" {
        let title = str_at(r, "/customTitle")
            .or_else(|| str_at(r, "/aiTitle"))
            .or_else(|| str_at(r, "/title"));
        out.push(Event::Info {
            cwd: None,
            title: title.map(str::to_owned),
        });
        return out;
    }
    if IGNORED.contains(&ty) {
        return out;
    }
    let uuid = str_at(r, "/uuid").unwrap_or("");
    let date = str_at(r, "/timestamp").and_then(iso);
    let (Some(date), false) = (date, uuid.is_empty()) else {
        out.push(Event::Unparsed(format!(
            "{ty} entry without uuid or timestamp"
        )));
        return out;
    };
    if let Some(cwd) = str_at(r, "/cwd") {
        out.push(Event::Info {
            cwd: Some(cwd.to_owned()),
            title: None,
        });
    }
    let item = |k: usize, kind: Kind, text: String, opens: bool, call: Option<String>| {
        Event::Item(Item {
            kind,
            text,
            date,
            src: Src {
                h: "claude".into(),
                s: session.to_owned(),
                e: if k == 0 {
                    uuid.to_owned()
                } else {
                    format!("{uuid}.{k}")
                },
            },
            opens,
            call,
            memory: false,
        })
    };
    match ty {
        "attachment" => {
            // Context the harness attaches, except messages the captain
            // typed while a turn ran, and background task notices.
            if str_at(r, "/attachment/type") == Some("queued_command") {
                let prompt = text_of(r.pointer("/attachment/prompt").unwrap_or(&Value::Null));
                let kind = match str_at(r, "/attachment/commandMode") {
                    Some("prompt") | None => Kind::User,
                    Some(_) => Kind::Echo,
                };
                if !prompt.trim().is_empty() && !injected(&prompt) {
                    out.push(item(0, kind, prompt, false, None));
                }
            }
        }
        "user" => {
            if flag("isMeta") || flag("isCompactSummary") {
                return out;
            }
            match r.pointer("/message/content").unwrap_or(&Value::Null) {
                Value::String(s) => {
                    if s.trim_start().starts_with("<task-notification>") {
                        out.push(item(0, Kind::Echo, s.clone(), false, None));
                    } else if interrupted(s) {
                        out.push(Event::TurnEnd);
                    } else if !injected(s) && !s.trim().is_empty() {
                        out.push(item(0, Kind::User, s.clone(), true, None));
                    }
                }
                Value::Array(blocks) => {
                    let (mut said, mut first) = (Vec::new(), None);
                    for (k, b) in blocks.iter().enumerate() {
                        if matches!(str_at(b, "/type"), Some("text" | "image" | "document")) {
                            first.get_or_insert(k);
                        }
                        match str_at(b, "/type") {
                            Some("text") => {
                                let t = str_at(b, "/text").unwrap_or("");
                                if interrupted(t) {
                                    out.push(Event::TurnEnd);
                                } else if !injected(t) && !t.trim().is_empty() {
                                    said.push(t.to_owned());
                                }
                            }
                            Some("image") => said.push("[image]".into()),
                            Some("document") => said.push("[document]".into()),
                            Some("tool_result") => out.push(item(
                                k,
                                Kind::Echo,
                                text_of(b.get("content").unwrap_or(&Value::Null)),
                                false,
                                str_at(b, "/tool_use_id").map(str::to_owned),
                            )),
                            other => out.push(Event::Unparsed(format!(
                                "user block {}",
                                other.unwrap_or("without a type")
                            ))),
                        }
                    }
                    if !said.is_empty() {
                        let k = first.unwrap_or(0);
                        out.insert(0, item(k, Kind::User, said.join("\n"), true, None));
                    }
                }
                _ => out.push(Event::Unparsed("user entry without content".into())),
            }
        }
        "assistant" => {
            let synthetic = str_at(r, "/message/model") == Some("<synthetic>");
            let blocks = r
                .pointer("/message/content")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            for (k, b) in blocks.iter().enumerate() {
                match str_at(b, "/type") {
                    Some("text") => {
                        let t = str_at(b, "/text").unwrap_or("").to_owned();
                        if !t.trim().is_empty() {
                            // An API error the harness reports as a reply.
                            let kind = if synthetic { Kind::Echo } else { Kind::Talk };
                            out.push(item(k, kind, t, false, None));
                        }
                    }
                    Some("tool_use" | "server_tool_use") => {
                        let input = b.get("input").unwrap_or(&Value::Null);
                        let mut call = item(
                            k,
                            Kind::Tool,
                            call_text(str_at(b, "/name").unwrap_or("?"), input),
                            false,
                            str_at(b, "/id").map(str::to_owned),
                        );
                        if let Event::Item(it) = &mut call {
                            it.memory = runs_memory(input);
                        }
                        out.push(call);
                    }
                    Some(t) if t.ends_with("_tool_result") => out.push(item(
                        k,
                        Kind::Echo,
                        text_of(b.get("content").unwrap_or(&Value::Null)),
                        false,
                        str_at(b, "/tool_use_id").map(str::to_owned),
                    )),
                    // A model switch mid-turn, with no content of its own.
                    Some("thinking" | "redacted_thinking" | "fallback") => {}
                    other => out.push(Event::Unparsed(format!(
                        "assistant block {}",
                        other.unwrap_or("without a type")
                    ))),
                }
            }
            match str_at(r, "/message/stop_reason") {
                Some("tool_use") => {}
                Some(_) => out.push(Event::TurnEnd),
                None if synthetic => out.push(Event::TurnEnd),
                None => {}
            }
        }
        other => out.push(Event::Unparsed(format!("entry type {other}"))),
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn model_fallback_is_skipped() {
        let r = json!({
            "type": "assistant", "uuid": "u1", "timestamp": "2026-07-25T21:07:32.543Z",
            "message": {"model": "claude-opus-4-8", "stop_reason": "tool_use",
                "content": [{"type": "fallback", "from": {"model": "a"}, "to": {"model": "b"}}]}
        });
        let events = parse(&r, "s");
        assert!(
            events
                .iter()
                .all(|e| !matches!(e, Event::Unparsed(_) | Event::Item(_)))
        );
    }
}
