//! Muse Code: `~/.local/share/muse/sessions/YYYY/MM/DD/<session>/session.jsonl`,
//! one event record per line in Muse's session protocol. Subagents and
//! observer agents write their own logs under `subagent/`; those are never
//! read. Muse logs some sixty kinds of event; only the five below are the
//! chat, and every other kind is the runtime's bookkeeping.

use super::{Event, Item, call_text, runs_memory, str_at, text_of};
use crate::memory::store::{Kind, Src};
use chrono::{DateTime, Local};
use serde_json::Value;

/// When a record was written: `recorded_at` is microseconds since the epoch.
pub fn date(r: &Value) -> Option<DateTime<Local>> {
    let us = r.get("recorded_at")?.as_i64()?;
    DateTime::from_timestamp_micros(us).map(|d| d.with_timezone(&Local))
}

pub fn parse(r: &Value, session: &str) -> Vec<Event> {
    let mut out = Vec::new();
    // Permission transactions wrap their records in a frame; none is chat.
    if r.get("retained_frame").is_some() {
        return out;
    }
    let p = r.get("payload").unwrap_or(&Value::Null);
    let ev = p.get("event").unwrap_or(&Value::Null);
    let kind = match str_at(r, "/payload_type") {
        Some("runtime.user_intent.accepted") => "user",
        Some("runtime.session.metadata") => {
            out.push(Event::Info {
                cwd: str_at(p, "/record/workspace_root").map(str::to_owned),
                title: None,
            });
            return out;
        }
        Some("session.name.changed") => {
            out.push(Event::Info {
                cwd: None,
                title: str_at(p, "/new_name").map(str::to_owned),
            });
            return out;
        }
        Some("runtime.session") if str_at(p, "/kind") == Some("run") => match str_at(ev, "/kind") {
            Some("terminal") => {
                out.push(Event::TurnEnd);
                return out;
            }
            Some(
                k @ ("assistant_message_committed"
                | "assistant_tool_calls_committed"
                | "tool_result_batch_committed"),
            ) => k,
            _ => return out,
        },
        _ => return out,
    };
    let Some(date) = date(r) else {
        out.push(Event::Unparsed(format!("{kind} without recorded_at")));
        return out;
    };
    let id = str_at(r, "/id").unwrap_or("?");
    let item = |kind, text: String, e: String, opens, call: Option<&str>| Item {
        kind,
        text,
        date,
        src: Src {
            h: "muse".into(),
            s: session.to_owned(),
            e,
        },
        opens,
        call: call.map(str::to_owned),
        memory: false,
    };
    match kind {
        "user" => {
            // Only the captain's chat reaches a session's own surface; hook
            // context and observer notes never become intents.
            if str_at(p, "/surface") != Some("main")
                || str_at(p, "/semantic_kind/kind") != Some("chat")
            {
                return out;
            }
            let text = p
                .get("model_messages")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .map(|m| text_of(m.get("content").unwrap_or(&Value::Null)))
                .collect::<Vec<_>>()
                .join("\n");
            if !text.trim().is_empty() {
                let e = str_at(p, "/intent_id").unwrap_or(id).to_owned();
                out.push(Event::Item(item(Kind::User, text, e, true, None)));
            }
        }
        "assistant_message_committed" => {
            let text = str_at(ev, "/text").unwrap_or("");
            if !text.trim().is_empty() {
                let e = str_at(ev, "/message_id").unwrap_or(id).to_owned();
                out.push(Event::Item(item(
                    Kind::Talk,
                    text.to_owned(),
                    e,
                    false,
                    None,
                )));
            }
        }
        "assistant_tool_calls_committed" => {
            for (i, call) in ev
                .get("tool_calls")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .enumerate()
            {
                let raw = str_at(call, "/args").unwrap_or("");
                let input = serde_json::from_str(raw).unwrap_or(Value::String(raw.to_owned()));
                let name = str_at(call, "/name").unwrap_or("?");
                let cid = str_at(call, "/call_id");
                let e = cid.map_or_else(|| format!("{id}#{i}"), str::to_owned);
                let mut it = item(Kind::Tool, call_text(name, &input), e, false, cid);
                it.memory = runs_memory(&input);
                out.push(Event::Item(it));
            }
        }
        _ => {
            for (i, res) in ev
                .get("results")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .enumerate()
            {
                let text = str_at(res, "/text").unwrap_or("").to_owned();
                let cid = str_at(res, "/tool_call_id");
                let e = cid.map_or_else(|| format!("{id}#{i}"), |c| format!("{c}>"));
                out.push(Event::Item(item(Kind::Echo, text, e, false, cid)));
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn run(event: Value) -> Value {
        json!({"id": "r1", "recorded_at": 1791844835524308i64, "record_type": "event",
               "payload_type": "runtime.session",
               "payload": {"kind": "run", "run_id": "x", "event": event}})
    }

    fn items(r: &Value) -> Vec<Item> {
        parse(r, "s")
            .into_iter()
            .filter_map(|e| match e {
                Event::Item(i) => Some(i),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn a_turn() {
        let user = json!({"id": "r0", "recorded_at": 1791844830646122i64,
            "payload_type": "runtime.user_intent.accepted",
            "payload": {"intent_id": "i1", "surface": "main", "semantic_kind": {"kind": "chat"},
                        "model_messages": [{"content": [{"kind": "text", "text": "code"}]}]}});
        let u = items(&user);
        assert_eq!(u.len(), 1);
        assert!(u[0].opens && u[0].kind == Kind::User && u[0].text == "code");
        assert_eq!(u[0].src.e, "i1");

        let talk = items(&run(json!({"kind": "assistant_message_committed",
            "message_id": "m1", "phase": "commentary", "text": "Looking."})));
        assert!(talk[0].kind == Kind::Talk && talk[0].text == "Looking.");

        let calls = items(&run(json!({"kind": "assistant_tool_calls_committed",
            "tool_calls": [{"name": "bash", "call_id": "c1", "args": "{\"command\":\"hippo view\"}"},
                           {"name": "bash", "call_id": "c2", "args": "{\"command\":\"ls\"}"}]})));
        assert_eq!(calls.len(), 2);
        assert!(calls[0].memory && !calls[1].memory);
        assert_eq!(calls[1].call.as_deref(), Some("c2"));

        let echo = items(&run(json!({"kind": "tool_result_batch_committed",
            "results": [{"tool_call_id": "c2", "tool_call_index": 0, "text": "a b"}]})));
        assert!(echo[0].kind == Kind::Echo && echo[0].call.as_deref() == Some("c2"));
        assert_ne!(echo[0].src.e, calls[1].src.e);

        assert!(matches!(
            parse(
                &run(json!({"kind": "terminal", "terminal": "completed"})),
                "s"
            )[..],
            [Event::TurnEnd]
        ));
    }

    #[test]
    fn bookkeeping_is_silent() {
        assert!(parse(&run(json!({"kind": "reasoning_committed"})), "s").is_empty());
        let frame = json!({"retained_frame": "session_permission_transaction", "children": []});
        assert!(parse(&frame, "s").is_empty());
        let side = json!({"id": "r", "recorded_at": 1i64, "payload_type": "runtime.user_intent.accepted",
            "payload": {"surface": "observer", "semantic_kind": {"kind": "chat"},
                        "model_messages": [{"content": [{"kind": "text", "text": "x"}]}]}});
        assert!(items(&side).is_empty());
    }
}
