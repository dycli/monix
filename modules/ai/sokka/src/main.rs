//! Sokka: the household assistant. One endless chat with no sessions: each
//! message from the captain becomes one fresh model call that sees Sokka's
//! prompt, its whole memory (its hippo view) and the new message. Both the
//! message and the answer go into hippo, so the next call remembers them.

mod hippo;
mod matrix;
mod model;

use chrono::Local;
use hippo::Hippo;
use matrix::{Fail, Matrix};
use model::Model;
use std::env;
use std::path::PathBuf;
use std::process::ExitCode;
use std::thread;
use std::time::Duration;

const PROMPT: &str = "\
You are Sokka, the household assistant of Dylan, who you talk with over \
Matrix. You are a steward: brief, warm, practical, with a light touch of \
humor. Answer in a sentence or two unless asked for more. Write plain \
text: Matrix shows no markdown.

<chat> is your memory: every message between you and Dylan, oldest \
first, one line each. Recent messages appear nearly whole; older lines \
cover more messages in fewer words, the older the more. Each line starts \
with its address (id+n: the n messages from id) and tags what Dylan said \
as user and what you said as talk. Rely on it as what you remember; when \
a line is too condensed to answer from, say what you remember and ask.

You have no tools yet: you cannot set reminders, read calendars, search \
the web or change anything. Say so plainly when asked, and never claim \
to have done something.";

fn var(k: &str) -> Result<String, String> {
    env::var(k)
        .ok()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| format!("{k} is not set"))
}

/// One message in, one answer out, both remembered.
fn answer(hippo: &Hippo, model: &dyn Model, text: &str) -> Result<String, String> {
    let view = hippo.view()?;
    hippo.log("user", text)?;
    let prompt = format!(
        "{view}\nNow: {}\n\nDylan: {text}",
        Local::now().format("%Y-%m-%d %a %H:%M")
    );
    let reply = model.answer(PROMPT, &prompt)?;
    if reply.is_empty() {
        return Err("the model answered nothing".into());
    }
    hippo.log("talk", &reply)?;
    Ok(reply)
}

fn run() -> Result<(), String> {
    let state = PathBuf::from(var("STATE_DIRECTORY")?);
    let users: Vec<String> = var("SOKKA_USERS")?
        .split(',')
        .map(|u| u.trim().to_owned())
        .collect();
    let hippo = Hippo {
        sock: PathBuf::from(var("HIPPO_DIR")?).join("hippo.sock"),
    };
    let model = model::from_env()?;
    let mut mx = Matrix::new(
        var("SOKKA_HOMESERVER")?,
        var("MATRIX_USER")?,
        var("MATRIX_PASSWORD")?,
        state.join("session.json"),
    );
    loop {
        if !mx.logged_in() {
            mx.login()?;
            eprintln!("sokka: logged in");
        }
        let news = match mx.sync() {
            Ok(news) => news,
            Err(Fail::Token) => {
                mx.forget_token();
                continue;
            }
            Err(Fail::Other(e)) => {
                eprintln!("sokka: sync: {e}");
                thread::sleep(Duration::from_secs(10));
                continue;
            }
        };
        for (room, inviter) in news.invites {
            let r = if users.contains(&inviter) {
                mx.join(&room)
            } else {
                mx.leave(&room)
            };
            if let Err(Fail::Other(e)) = r {
                eprintln!("sokka: invite to {room}: {e}");
            }
        }
        for m in news.messages {
            if !users.contains(&m.sender) {
                continue;
            }
            let _ = mx.typing(&m.room, true);
            let reply = answer(&hippo, model.as_ref(), &m.body).unwrap_or_else(|e| {
                eprintln!("sokka: {e}");
                format!("(I couldn't answer that: {e})")
            });
            let _ = mx.typing(&m.room, false);
            if let Err(Fail::Other(e)) = mx.send(&m.room, &reply) {
                eprintln!("sokka: send to {}: {e}", m.room);
            }
        }
    }
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("sokka: {e}");
            ExitCode::FAILURE
        }
    }
}
