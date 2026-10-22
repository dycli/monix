//! Claude Code: `~/.claude/projects/<project>/<session>.jsonl`, one entry
//! per line, one content block per assistant entry. Subagents write their
//! own files one directory deeper, `<session>/subagents/agent-<id>.jsonl`:
//! those stay out of the timeline, which gets only each one's report, and
//! are read whole when asked for (`agent`).

use super::{Event, Item, call_text, iso, report, runs_memory, str_at, text_of};
use crate::memory::mask::mask;
use crate::memory::store::{Kind, Src};
use serde_json::Value;
use std::fs;
use std::path::PathBuf;

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

/// A report from one of a yeoman seat's agents, which the yeoman hands the
/// seat as its prompt, tagged: the agent's words, not the captain's.
fn agent_report(text: &str) -> Option<String> {
    let rest = text.trim_start().strip_prefix("<agent-report>")?;
    let (said, _) = rest.split_once("</agent-report>")?;
    Some(said.trim().to_owned())
}

fn interrupted(text: &str) -> bool {
    text.starts_with("[Request interrupted by user")
}

pub fn parse(r: &Value, session: &str) -> Vec<Event> {
    if r.get("isSidechain") == Some(&Value::Bool(true)) {
        return Vec::new();
    }
    entry(r, session)
}

/// An entry of the seat's chat or of a subagent's.
pub fn entry(r: &Value, session: &str) -> Vec<Event> {
    let mut out = Vec::new();
    let Some(ty) = str_at(r, "/type") else {
        out.push(Event::Unparsed("entry without a type".into()));
        return out;
    };
    let flag = |k: &str| r.get(k) == Some(&Value::Bool(true));
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
            // A subagent's report comes as a meta entry from it, beside the
            // task notice that only points to it.
            if r.pointer("/origin/handback") == Some(&Value::Bool(true)) {
                let name = str_at(r, "/origin/from").unwrap_or("agent");
                let text = str_at(r, "/origin/handbackReportText")
                    .or_else(|| str_at(r, "/origin/body"))
                    .unwrap_or("");
                out.push(item(0, Kind::Work, report(name, text), false, None));
                return out;
            }
            if flag("isMeta") || flag("isCompactSummary") {
                return out;
            }
            match r.pointer("/message/content").unwrap_or(&Value::Null) {
                Value::String(s) => {
                    if let Some(said) = agent_report(s) {
                        out.push(item(0, Kind::Work, said, false, None));
                    } else if s.trim_start().starts_with("<task-notification>") {
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
                                if let Some(said) = agent_report(t) {
                                    out.push(item(k, Kind::Work, said, false, None));
                                } else if interrupted(t) {
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

/// Characters of a subagent's chat one zoom shows.
const PAGE: usize = 20_000;

/// A subagent's whole chat, `i|kind: text` per message as Unii shows one,
/// from character `at`, a page at a time. `name` is its agent id.
pub fn agent(roots: &[PathBuf], name: &str, at: usize) -> Result<String, String> {
    if name.is_empty() || !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
        return Err(format!("No agent {name}."));
    }
    let file = format!("agent-{name}.jsonl");
    let found = roots
        .iter()
        .flat_map(|r| fs::read_dir(r).into_iter().flatten().flatten())
        .flat_map(|project| fs::read_dir(project.path()).into_iter().flatten().flatten())
        .map(|session| session.path().join("subagents").join(&file))
        .find(|p| p.is_file())
        .ok_or_else(|| format!("No agent {name}."))?;
    let raw = fs::read_to_string(&found).map_err(|e| format!("{}: {e}", found.display()))?;
    let mut lines = Vec::new();
    for r in raw
        .lines()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
    {
        for e in entry(&r, name) {
            if let Event::Item(it) = e {
                lines.push(format!("{}|{}: {}", lines.len(), it.kind.name(), it.text));
            }
        }
    }
    let all = mask(&lines.join("\n\n"));
    let chars: Vec<char> = all.chars().collect();
    let from = at.min(chars.len());
    let to = (from + PAGE).min(chars.len());
    let mut out: String = chars[from..to].iter().collect();
    if to < chars.len() {
        out.push_str(&format!(
            "\n\n(more from character {to} of {}: hippo zoom {name} {to})",
            chars.len()
        ));
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_subagents_report_is_work() {
        let r = json!({
            "type": "user", "isMeta": true, "isSidechain": false,
            "uuid": "u2", "timestamp": "2026-10-21T12:05:00.000Z",
            "message": {"role": "user", "content": "Another Claude session sent a message: ..."},
            "origin": {"kind": "peer", "from": "a397cb89b04502782", "handback": true,
                "body": "[Subagent hand-back] framed", "handbackReportText": "## Audit\nAll good."}
        });
        let events = parse(&r, "s");
        let [Event::Item(it)] = events.as_slice() else {
            panic!("{events:?}");
        };
        assert_eq!(it.kind, Kind::Work);
        assert_eq!(
            it.text,
            "[a397cb89b04502782]\n## Audit\nAll good.\n\nFull chat: hippo zoom a397cb89b04502782"
        );
        let other = json!({"type": "user", "isMeta": true, "uuid": "u3",
            "timestamp": "2026-10-21T12:05:00.000Z", "message": {"role": "user", "content": "x"}});
        assert!(parse(&other, "s").is_empty());
    }

    #[test]
    fn a_seat_agents_report_is_work() {
        let said = "<agent-report>\n[Ada] report\nDone.\n</agent-report>\n\nFrom your subagent.";
        let r = json!({
            "type": "user", "uuid": "u4", "timestamp": "2026-10-22T12:05:00.000Z",
            "message": {"role": "user", "content": [{"type": "text", "text": said}]}
        });
        let events = parse(&r, "s");
        let [Event::Item(it)] = events.as_slice() else {
            panic!("{events:?}");
        };
        assert_eq!(
            (it.kind, it.text.as_str()),
            (Kind::Work, "[Ada] report\nDone.")
        );
    }

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
