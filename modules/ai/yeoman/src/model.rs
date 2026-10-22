//! The model behind the yeoman, one call per message. Which backend runs it is
//! configuration: the `claude` CLI on a subscription, or any
//! OpenAI-compatible endpoint (local llama.cpp, a hosted API).

use base64::Engine;
use base64::engine::general_purpose::STANDARD as B64;
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::Path;

use crate::keep;
use std::process::{ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
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

    /// Whether the model is the seat itself, which brings its own rules,
    /// memory and tools: it takes no memory, clock or yeoman prompt.
    fn seat(&self) -> bool {
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
            seat: var("YEOMAN_SEAT_MODE").is_some(),
        })),
        "http" => Ok(Box::new(Http {
            url: var("YEOMAN_URL").ok_or("YEOMAN_URL is not set")?,
            model: var("YEOMAN_MODEL").ok_or("YEOMAN_MODEL is not set")?,
        })),
        other => Err(format!("Unknown YEOMAN_BACKEND {other}.")),
    }
}

/// The models the person may switch between on the page (YEOMAN_MODELS,
/// comma-separated); none when the model is fixed.
pub fn choices() -> Vec<String> {
    std::env::var("YEOMAN_MODELS")
        .unwrap_or_default()
        .split(',')
        .map(str::trim)
        .filter(|m| !m.is_empty())
        .map(str::to_owned)
        .collect()
}

/// The model the person picked, kept in the state directory; none until
/// they pick one, or once it is no longer among the choices.
pub fn picked(state: &Path) -> Option<String> {
    let m = std::fs::read_to_string(state.join("model")).ok()?;
    let m = m.trim();
    choices().iter().any(|c| c == m).then(|| m.to_owned())
}

/// Keeps the person's pick for the turns after this one.
pub fn pick(state: &Path, model: &str) -> Result<(), String> {
    if !choices().iter().any(|c| c == model) {
        return Err(format!("{model} is not among the choices"));
    }
    std::fs::write(state.join("model"), model).map_err(|e| e.to_string())
}

/// The `claude` CLI in print mode: no built-in tools, no settings sources
/// (so no hooks), no session saved; only the MCP servers in YEOMAN_MCP.
/// How a turn runs: whether it may act, what stops it, and whether it
/// has a clock on it (a subagent has none).
#[derive(Clone, Default)]
pub struct Run {
    pub acts: bool,
    pub stop: Option<Arc<AtomicBool>>,
    pub endless: bool,
    /// A subagent's, by its name: it can't start or tell agents of its own.
    pub sub: Option<String>,
    /// Where each tool call and its result go as they happen, for a door
    /// that shows the work as well as the answer.
    pub steps: Option<Steps>,
    /// Where the person's next words go while this turn runs.
    pub steer: Option<Arc<Steer>>,
    /// Who answers the seat's questions and permission prompts; without
    /// one they are refused, as `claude -p` refuses what it would ask.
    pub ask: Option<Arc<dyn Asker>>,
}

/// The way into the turn under way: words written here reach the model at
/// its next step, as Claude Code takes a message typed while it works. It
/// is open from the turn's first words until its answer is out.
#[derive(Default)]
pub struct Steer {
    into: Mutex<Option<ChildStdin>>,
}

impl Steer {
    /// Hands `text` to the turn under way; false when none will read it,
    /// and it should wait its turn instead.
    pub fn send(&self, text: &str) -> bool {
        let mut into = self.into.lock().unwrap();
        let Some(stdin) = into.as_mut() else {
            return false;
        };
        let line = user(vec![json!({"type": "text", "text": text})]);
        if stdin
            .write_all(line.as_bytes())
            .and_then(|()| stdin.flush())
            .is_err()
        {
            *into = None;
            return false;
        }
        true
    }

    /// Whether a turn is under way to take words.
    pub fn running(&self) -> bool {
        self.into.lock().unwrap().is_some()
    }

    fn open(&self, stdin: ChildStdin) {
        *self.into.lock().unwrap() = Some(stdin);
    }

    /// Answers the CLI's control request `id`, while the input is open.
    fn respond(&self, id: &str, response: Value) {
        let line = json!({"type": "control_response",
            "response": {"subtype": "success", "request_id": id, "response": response}});
        if let Some(stdin) = self.into.lock().unwrap().as_mut() {
            let _ = writeln!(stdin, "{line}").and_then(|()| stdin.flush());
        }
    }

    /// Ends the input: the CLI exits once it has answered what it has.
    fn close(&self) {
        self.into.lock().unwrap().take();
    }
}

/// One user message as a stream-json input line.
fn user(content: Vec<Value>) -> String {
    format!(
        "{}\n",
        json!({"type": "user", "message": {"role": "user", "content": content}})
    )
}

pub type Steps = Arc<dyn Fn(Step) + Send + Sync>;

/// What the seat's CLI asks the person mid-turn, as Claude Code would in a
/// terminal: whether `tool` may run with `input`, or, for AskUserQuestion,
/// the questions in `input`.
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Ask {
    pub id: String,
    pub tool: String,
    pub input: Value,
    /// The CLI's own words on what the call does, when it has them.
    pub about: Option<String>,
}

/// Puts an ask to the person and waits for them: the input the tool runs
/// with (for questions, holding the answers), or None to refuse it.
pub trait Asker: Send + Sync {
    fn put(&self, ask: Ask) -> Option<Value>;
    /// The CLI took its question back, or the turn ended without answer.
    fn withdraw(&self, id: &str);
}

/// The CLI's question in one stream-json line, when it asks one.
fn ask_of(ev: &Value) -> Option<Ask> {
    let r = &ev["request"];
    (ev["type"] == "control_request" && r["subtype"] == "can_use_tool").then(|| Ask {
        id: ev["request_id"].as_str().unwrap_or_default().to_owned(),
        tool: r["tool_name"].as_str().unwrap_or_default().to_owned(),
        input: r["input"].clone(),
        about: r["description"].as_str().map(str::to_owned),
    })
}

/// Takes back the asks a turn leaves unanswered as it ends.
fn withdraw(asker: &Option<Arc<dyn Asker>>, open: &Mutex<Vec<String>>) {
    if let Some(a) = asker {
        open.lock()
            .unwrap()
            .drain(..)
            .for_each(|id| a.withdraw(&id));
    }
}

/// The CLI's word for an answer: run with this input, or don't.
fn verdict(input: Option<Value>) -> Value {
    match input {
        Some(input) => json!({"behavior": "allow", "updatedInput": input}),
        None => {
            json!({"behavior": "deny", "message": "Refused: the person said no, or no one was there to answer."})
        }
    }
}

/// The most of a tool's result a door is shown; the model reads it all.
pub const STEP_MAX: usize = 16 * 1024;

/// One step of the work behind an answer.
#[derive(Clone, Debug, PartialEq, serde::Serialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Step {
    /// The model calls `name` (`mcp__server__tool`) with `input`.
    Call {
        id: String,
        name: String,
        input: Value,
    },
    /// What the call `id` gave back: its text, cut to STEP_MAX.
    Result {
        id: String,
        text: String,
        error: bool,
    },
    /// More of the words being written, as they come.
    Text { text: String },
    /// A subagent's or the seat's whole answer to one message: a subagent
    /// keeps it in its log, the seat says it at once. Steered runs give one
    /// per message. Doors never see it.
    Answer { text: String },
    /// The seat's Agent call `id` started a subagent, `name` its
    /// description and `task` its prompt.
    Agent {
        id: String,
        name: String,
        task: String,
    },
    /// The subagent of Agent call `id` stopped, with its report.
    Done { id: String, report: String },
    /// A step of the subagent the seat's Agent call `parent` started: the
    /// CLI puts its work on the seat's stream, tagged, as Claude Code
    /// nests it under the call. It is the subagent's, not the answer's.
    Inner { parent: String, step: Box<Step> },
}

/// The answer in one stream-json line, when it ends a reply that didn't
/// fail.
fn answer(line: &str) -> Option<String> {
    let ev = serde_json::from_str::<Value>(line).ok()?;
    if ev["type"] != "result" || ev["is_error"] == true {
        return None;
    }
    let text = ev["result"].as_str()?.trim();
    said(text).then(|| text.to_owned())
}

/// A seat's whole answer to a background job's news that tells the person
/// nothing new (OpenClaw's convention): asked for an empty reply, the model
/// writes one saying it is silent instead.
pub const QUIET: &str = "NO_REPLY";

/// Whether an answer is one to pass on.
fn said(text: &str) -> bool {
    !text.is_empty() && text != QUIET
}

/// How many background jobs run, when the line says it changed.
fn background_tasks(line: &str) -> Option<usize> {
    if !line.contains("background_tasks_changed") {
        return None;
    }
    let ev = serde_json::from_str::<Value>(line).ok()?;
    (ev["subtype"] == "background_tasks_changed")
        .then(|| ev["tasks"].as_array().map_or(0, Vec::len))
}

/// The name every turn of the seat goes by, as Claude Code titles its
/// sessions and hippo its chats.
pub fn seat_name() -> String {
    std::env::var("YEOMAN_NAME").unwrap_or_else(|_| "yeoman".into())
}

/// The steps in one stream-json line: tool calls from the model, results
/// from the tools. Claude Code reports results as a user turn.
pub fn steps(line: &str) -> Vec<Step> {
    let Ok(ev) = serde_json::from_str::<Value>(line) else {
        return vec![];
    };
    let parts = ev["message"]["content"].as_array().into_iter().flatten();
    let s = |v: &Value| v.as_str().unwrap_or_default().to_owned();
    if let Some(parent) = ev["parent_tool_use_id"].as_str() {
        // A subagent's words come whole, never as deltas.
        let words = parts
            .clone()
            .filter(|c| ev["type"] == "assistant" && c["type"] == "text")
            .map(|c| Step::Text {
                text: s(&c["text"]),
            });
        let mut own = vec![];
        if ev["type"] != "stream_event" {
            let mut plain = ev.clone();
            plain["parent_tool_use_id"] = Value::Null;
            own = steps(&plain.to_string());
        }
        return words
            .chain(own)
            .map(|step| Step::Inner {
                parent: parent.to_owned(),
                step: Box::new(step),
            })
            .collect();
    }
    match (ev["type"].as_str(), ev["subtype"].as_str()) {
        (Some("system"), Some("task_started")) if ev["task_type"] == "local_agent" => {
            return vec![Step::Agent {
                id: s(&ev["tool_use_id"]),
                name: s(&ev["description"]),
                task: s(&ev["prompt"]),
            }];
        }
        (Some("system"), Some("task_notification")) if ev["tool_use_id"].is_string() => {
            return vec![Step::Done {
                id: s(&ev["tool_use_id"]),
                report: s(&ev["summary"]),
            }];
        }
        _ => {}
    }
    match ev["type"].as_str() {
        // With --include-partial-messages, the words arrive as deltas
        // before the whole message does.
        Some("stream_event")
            if ev["event"]["type"] == "content_block_delta"
                && ev["event"]["delta"]["type"] == "text_delta" =>
        {
            vec![Step::Text {
                text: s(&ev["event"]["delta"]["text"]),
            }]
        }
        Some("assistant") => parts
            .filter(|c| c["type"] == "tool_use")
            .map(|c| Step::Call {
                id: s(&c["id"]),
                name: s(&c["name"]),
                input: c["input"].clone(),
            })
            .collect(),
        Some("user") => parts
            .filter(|c| c["type"] == "tool_result")
            .map(|c| {
                let mut text = match &c["content"] {
                    Value::String(t) => t.clone(),
                    Value::Array(a) => a
                        .iter()
                        .filter_map(|p| p["text"].as_str())
                        .collect::<Vec<_>>()
                        .join("\n"),
                    _ => String::new(),
                };
                if text.len() > STEP_MAX {
                    let mut cut = STEP_MAX;
                    while !text.is_char_boundary(cut) {
                        cut -= 1;
                    }
                    text.truncate(cut);
                }
                Step::Result {
                    id: s(&c["tool_use_id"]),
                    text,
                    error: c["is_error"] == true,
                }
            })
            .collect(),
        _ => vec![],
    }
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
    /// Seat mode: Claude Code as the seat runs it, with its own settings,
    /// hooks, rules, MCP servers and built-in tools, the session kept for
    /// hippo's watcher. The memory arrives through the rules, so none is
    /// sent; the turn has no clock, as the seat's don't.
    pub seat: bool,
}

/// The tools that act on the world, by MCP name.
const ACTS: &str = "mcp__yeoman__remind,mcp__yeoman__cancel_reminder,mcp__yeoman__list_add,\
mcp__yeoman__share_list,mcp__yeoman__list_remove,mcp__yeoman__tell,mcp__yeoman__draft_mail,mcp__yeoman__add_event,\
mcp__yeoman__change_event,mcp__yeoman__cancel_event,mcp__image__make_image,mcp__yeoman__web_fetch,\
mcp__computer,mcp__home,mcp__yeoman__media_request,mcp__yeoman__spawn,mcp__yeoman__tell_agent,mcp__yeoman__cancel_task,\
mcp__yeoman__show_page,mcp__yeoman__money_change,mcp__yeoman__watch,mcp__yeoman__unwatch,mcp__yeoman__run_code";

/// The yeoman's own hold on its subagents, which they don't share: as in
/// Unii, one level of agents.
const BOSS: &str =
    "mcp__yeoman__spawn,mcp__yeoman__tell_agent,mcp__yeoman__cancel_task,mcp__yeoman__agent_chat";

impl Model for Claude {
    fn answer(
        &self,
        system: &str,
        memory: &str,
        prompt: &str,
        files: &[Attachment],
        run: Run,
    ) -> Result<String, String> {
        let model = std::env::var_os("STATE_DIRECTORY")
            .and_then(|s| picked(Path::new(&s)))
            .unwrap_or_else(|| self.model.clone());
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
        ]);
        if self.seat {
            // Every turn its own session, all under one name. An agent's
            // runs keep no session: its log in the yeoman's state is its
            // chat, and hippo hears of it only through its report.
            let name = match &run.sub {
                Some(agent) => {
                    cmd.arg("--no-session-persistence");
                    format!("{} {agent}", seat_name())
                }
                None => seat_name(),
            };
            // The seat's agents come through the host's managed MCP server
            // `yeoman agents`, which finds this yeoman's state here; one
            // level, as in Unii.
            match (&run.sub, std::env::var_os("STATE_DIRECTORY")) {
                (None, Some(state)) => {
                    cmd.env("YEOMAN_AGENTS", state)
                        .args(["--allowedTools", BOSS]);
                }
                _ => {
                    cmd.env_remove("YEOMAN_AGENTS");
                }
            }
            cmd.args([
                "--name",
                &name,
                "--permission-mode",
                "auto",
                // What it would ask in a terminal comes as control
                // requests on stdout, answered on stdin (as the Agent SDK's
                // canUseTool), which the page shows as cards.
                "--permission-prompt-tool",
                "stdio",
                "--append-system-prompt",
                system,
                "--model",
                &model,
            ]);
        } else {
            cmd.args([
                "--no-session-persistence",
                "--system-prompt",
                system,
                "--tools",
                "",
                "--strict-mcp-config",
                "--setting-sources",
                "",
                "--model",
                &model,
            ]);
        }
        if let Some(effort) = &self.effort {
            cmd.args(["--effort", effort]);
        }
        if run.steps.is_some() {
            cmd.arg("--include-partial-messages");
        }
        if let Some((file, servers)) = &self.mcp {
            let allowed: Vec<String> = servers.iter().map(|s| format!("mcp__{s}")).collect();
            cmd.args(["--mcp-config", file, "--allowedTools", &allowed.join(",")]);
            let mut denied = Vec::new();
            if run.sub.is_some() {
                denied.push(BOSS);
            }
            if !run.acts {
                denied.push(ACTS);
            }
            if !denied.is_empty() {
                cmd.args(["--disallowedTools", &denied.join(",")]);
            }
        }
        let mut child = cmd
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("{}: {e}", self.command))?;
        let mut content = if self.seat {
            Vec::new()
        } else {
            cached(memory)
        };
        content.extend(files.iter().map(|f| match f {
            Attachment::Image { mime, data } => json!({"type": "image",
                    "source": {"type": "base64", "media_type": mime, "data": B64.encode(data)}}),
            Attachment::Pdf(data) => json!({"type": "document",
                    "source": {"type": "base64", "media_type": "application/pdf",
                               "data": B64.encode(data)}}),
        }));
        content.push(json!({"type": "text", "text": prompt}));
        let line = user(content);
        let mut stdin = child.stdin.take().unwrap();
        // The seat's input stays open for its answers to the CLI's
        // questions, even when no one's words can steer it.
        let run_steer = run.steer.clone().or_else(|| self.seat.then(Arc::default));
        // Written from a thread, as the files can outgrow the pipe; then,
        // with a steer, the input stays open for the person's next words.
        let steer = run_steer.clone();
        let writer = thread::spawn(move || {
            stdin.write_all(line.as_bytes())?;
            if let Some(s) = steer {
                s.open(stdin);
            }
            Ok::<_, std::io::Error>(())
        });
        let stdout = child.stdout.take().unwrap();
        let keep = self.keep.clone();
        let steps = run.steps.clone();
        let steer = run_steer.clone();
        let sub = run.sub.is_some();
        let seat = self.seat;
        let asker = run.ask.clone();
        // The asks still waiting on the person, withdrawn when the turn ends.
        let open: Arc<Mutex<Vec<String>>> = Arc::default();
        let asking = open.clone();
        let reader = thread::spawn(move || -> std::io::Result<(String, Option<String>)> {
            let mut out = String::new();
            // The reply's last computer tool, once it drives the computer.
            let mut used: Option<String> = None;
            // The seat's background jobs still running: the CLI wakes the
            // model when each ends, and answers again.
            let mut background = 0;
            for line in BufReader::new(stdout).lines() {
                let line = line?;
                if let Some(n) = background_tasks(&line) {
                    background = n;
                }
                if line.contains("control_") {
                    let ev = serde_json::from_str::<Value>(&line).unwrap_or_default();
                    if let (Some(ask), Some(s)) = (ask_of(&ev), &steer) {
                        let (s, asker, asking) = (s.clone(), asker.clone(), asking.clone());
                        // Each waits on the person in a thread of its own, so
                        // the stream reads on meanwhile.
                        thread::spawn(move || {
                            let id = ask.id.clone();
                            asking.lock().unwrap().push(id.clone());
                            let input = asker.and_then(|a| a.put(ask));
                            asking.lock().unwrap().retain(|a| *a != id);
                            s.respond(&id, verdict(input));
                        });
                    } else if ev["type"] == "control_cancel_request"
                        && let (Some(a), Some(id)) = (&asker, ev["request_id"].as_str())
                    {
                        a.withdraw(id);
                    }
                }
                if let Some(call) = keep::computer_call(&line) {
                    // The browser is leased the moment the reply first drives
                    // it, before the reply's own session ends and closes it.
                    if let (None, Some(url)) = (&used, &keep)
                        && let Err(e) = keep::hold(url, keep::LEASE)
                    {
                        eprintln!("yeoman: {e}");
                    }
                    used = Some(call);
                }
                if let Some(show) = &steps {
                    self::steps(&line).into_iter().for_each(|s| show(s));
                }
                // Words that came after the answer was out wait for the
                // next turn; ones already written the CLI answers next. The
                // seat stays open while its background jobs run, so the
                // person talks to it meanwhile, as in a Claude Code session.
                if let Some(s) = &steer
                    && (!seat || background == 0)
                    && line.contains(r#""result""#)
                    && serde_json::from_str::<Value>(&line)
                        .is_ok_and(|ev| ev.get("type").and_then(Value::as_str) == Some("result"))
                {
                    s.close();
                }
                if let (true, Some(show)) = (sub || seat, &steps)
                    && let Some(text) = answer(&line)
                {
                    show(Step::Answer { text });
                }
                out.push_str(&line);
                out.push('\n');
            }
            Ok((out, used))
        });
        let errors = drain(child.stderr.take().unwrap());
        let deadline = (!run.endless && !self.seat).then(|| Instant::now() + TIMEOUT);
        let status = loop {
            if let Some(status) = child.try_wait().map_err(|e| e.to_string())? {
                break status;
            }
            let stopped = run.stop.as_ref().is_some_and(|s| s.load(Ordering::Relaxed));
            if stopped || deadline.is_some_and(|d| Instant::now() > d) {
                if let Some(s) = &run_steer {
                    s.close();
                }
                withdraw(&run.ask, &open);
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
        if let Some(s) = &run_steer {
            s.close();
        }
        withdraw(&run.ask, &open);
        let (out, used) = reader.join().unwrap().map_err(|e| e.to_string())?;
        // A reply that ends by closing the browser lets it go; otherwise the
        // lease runs on from the reply's last use.
        if let (Some(call), Some(url)) = (used, &self.keep) {
            let kept = if call == "browser_close" {
                keep::release(url)
            } else {
                keep::hold(url, keep::LEASE)
            };
            if let Err(e) = kept {
                eprintln!("yeoman: {e}");
            }
        }
        // Words that reached the CLI just as an answer ended get one of
        // their own: each result is an answer, the last one holding the
        // call's usage.
        let results: Vec<Value> = out
            .lines()
            .filter_map(|l| serde_json::from_str::<Value>(l).ok())
            .filter(|ev| ev.get("type").and_then(Value::as_str) == Some("result"))
            .collect();
        let answers: Vec<&str> = results
            .iter()
            .filter(|ev| ev.get("is_error") != Some(&Value::Bool(true)))
            .filter_map(|ev| ev.get("result").and_then(Value::as_str))
            .map(str::trim)
            .filter(|t| said(t))
            .collect();
        // A subagent reports only its last answer, as in Unii: words sent
        // while it works replace what it said before, and its log keeps
        // every answer for whoever reads the whole chat.
        let answers = if run.sub.is_some() {
            answers.last().copied().unwrap_or_default().to_owned()
        } else {
            answers.join("\n\n")
        };
        let ev = match results.last() {
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
        if ev.get("is_error") == Some(&Value::Bool(true)) && answers.is_empty() {
            return Err(format!("claude: {}", tail(text)));
        }
        Ok(answers)
    }

    fn tools(&self) -> bool {
        self.mcp.is_some()
    }

    fn seat(&self) -> bool {
        self.seat
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

    #[test]
    fn a_subagents_work_is_its_own() {
        let started = r#"{"type":"system","subtype":"task_started","task_id":"a6","tool_use_id":"t1","description":"Count files","task_type":"local_agent","prompt":"Run ls"}"#;
        assert_eq!(
            steps(started),
            vec![Step::Agent {
                id: "t1".into(),
                name: "Count files".into(),
                task: "Run ls".into()
            }]
        );
        let bash = r#"{"type":"system","subtype":"task_started","task_id":"b1","tool_use_id":"t9","description":"sleep","task_type":"local_bash"}"#;
        assert_eq!(steps(bash), vec![]);
        let call = r#"{"type":"assistant","parent_tool_use_id":"t1","message":{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"Counting"},{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"ls"}}]}}"#;
        let inner = |step| Step::Inner {
            parent: "t1".into(),
            step: Box::new(step),
        };
        assert_eq!(
            steps(call),
            vec![
                inner(Step::Text {
                    text: "Counting".into()
                }),
                inner(Step::Call {
                    id: "t2".into(),
                    name: "Bash".into(),
                    input: serde_json::json!({"command": "ls"}),
                }),
            ]
        );
        let result = r#"{"type":"user","parent_tool_use_id":"t1","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"101"}]}}"#;
        assert_eq!(
            steps(result),
            vec![inner(Step::Result {
                id: "t2".into(),
                text: "101".into(),
                error: false
            })]
        );
        let done = r#"{"type":"system","subtype":"task_notification","task_id":"a6","tool_use_id":"t1","status":"completed","summary":"101"}"#;
        assert_eq!(
            steps(done),
            vec![Step::Done {
                id: "t1".into(),
                report: "101".into()
            }]
        );
    }

    #[test]
    fn steps_from_stream() {
        let call = r#"{"type":"assistant","message":{"content":[{"type":"text","text":"Looking"},{"type":"tool_use","id":"t1","name":"mcp__calendar__events","input":{"days":7}}]}}"#;
        assert_eq!(
            steps(call),
            vec![Step::Call {
                id: "t1".into(),
                name: "mcp__calendar__events".into(),
                input: serde_json::json!({"days": 7}),
            }]
        );
        let result = r#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"a"},{"type":"image"},{"type":"text","text":"b"}],"is_error":true}]}}"#;
        assert_eq!(
            steps(result),
            vec![Step::Result {
                id: "t1".into(),
                text: "a\nb".into(),
                error: true
            }]
        );
        let long = format!(
            r#"{{"type":"user","message":{{"content":[{{"type":"tool_result","tool_use_id":"t2","content":"{}é"}}]}}}}"#,
            "x".repeat(STEP_MAX - 1)
        );
        match &steps(&long)[..] {
            [
                Step::Result {
                    text, error: false, ..
                },
            ] => assert_eq!(text.len(), STEP_MAX - 1),
            other => panic!("{other:?}"),
        }
        let delta = r#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}}"#;
        assert_eq!(steps(delta), vec![Step::Text { text: "Hel".into() }]);
        let start = r#"{"type":"stream_event","event":{"type":"content_block_start","index":0}}"#;
        assert!(steps(start).is_empty());
        assert!(steps(r#"{"type":"result","result":"hi"}"#).is_empty());
        assert!(steps("not json").is_empty());
    }

    #[test]
    fn answer_from_stream() {
        assert_eq!(
            answer(r#"{"type":"result","result":" hi \n"}"#),
            Some("hi".into())
        );
        assert_eq!(
            answer(r#"{"type":"result","result":"no","is_error":true}"#),
            None
        );
        assert_eq!(answer(r#"{"type":"result","result":"  "}"#), None);
        assert_eq!(answer(r#"{"type":"result","result":"NO_REPLY\n"}"#), None);
        assert_eq!(answer(r#"{"type":"assistant","result":"hi"}"#), None);
        assert_eq!(answer("not json"), None);
    }

    #[test]
    fn asks_from_stream() {
        let ev: Value = serde_json::from_str(
            r#"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool",
            "tool_name":"Write","input":{"file_path":"/tmp/a"},"description":"a"}}"#,
        )
        .unwrap();
        let ask = ask_of(&ev).unwrap();
        assert_eq!((ask.id.as_str(), ask.tool.as_str()), ("r1", "Write"));
        assert_eq!(ask.about.as_deref(), Some("a"));
        assert!(ask_of(&json!({"type": "result"})).is_none());
        assert_eq!(verdict(Some(json!({"x": 1})))["behavior"], "allow");
        assert_eq!(verdict(None)["behavior"], "deny");
    }

    #[test]
    fn background_from_stream() {
        let changed = |tasks: &str| {
            format!(r#"{{"type":"system","subtype":"background_tasks_changed","tasks":{tasks}}}"#)
        };
        assert_eq!(background_tasks(&changed(r#"[{"task_id":"b1"}]"#)), Some(1));
        assert_eq!(background_tasks(&changed("[]")), Some(0));
        assert_eq!(background_tasks(r#"{"type":"result","result":"hi"}"#), None);
    }
}
