//! Sokka: the household assistant. One endless chat with no sessions: each
//! message from the captain becomes one fresh model call that sees Sokka's
//! prompt, its whole memory (its hippo view) and the new message. Both the
//! message and the answer go into hippo, so the next call remembers them.

mod book;
mod hippo;
mod matrix;
mod model;
mod tools;

use chrono::Local;
use hippo::Hippo;
use matrix_sdk::config::SyncSettings;
use matrix_sdk::ruma::OwnedRoomId;
use matrix_sdk::ruma::events::room::encrypted::OriginalSyncRoomEncryptedEvent;
use matrix_sdk::ruma::events::room::member::StrippedRoomMemberEvent;
use matrix_sdk::ruma::events::room::message::{
    MessageType, OriginalSyncRoomMessageEvent, RoomMessageEventContent,
};
use matrix_sdk::{Client, Room, RoomState};
use model::Model;
use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

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
a line is too condensed to answer from, say what you remember and ask.";

/// Added when the model has no tools.
const NO_TOOLS: &str = "\n\nYou cannot set reminders, keep lists or change anything. Say so \
plainly when asked, and never claim to have done something.";

/// Added when the model has tools.
const TOOLS: &str = "\n\nYou can search the web and read pages. Search when the answer depends on \
current or local facts (hours, prices, news, availability) or on \
anything you are unsure of; skip it for what you know or remember. Give \
the answer, not the search: say where it came from in a few words, add a \
link only when Dylan will want to open it, and say plainly when the \
sources disagree or come up empty.

You keep Dylan's reminders and lists. Set a reminder when Dylan asks \
for one, at the time Dylan means, worked out from Now; you send it then, \
word for word, so write it as the reminder itself. Keep lists Dylan \
names (groceries, errands) with the list tools, and show a list when \
asked rather than recalling it. Say something is done only once a tool \
has done it.";

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
    let system = format!("{PROMPT}{}", if model.tools() { TOOLS } else { NO_TOOLS });
    let reply = model.answer(&system, &prompt)?;
    if reply.is_empty() {
        return Err("the model answered nothing".into());
    }
    hippo.log("talk", &reply)?;
    Ok(reply)
}

/// Joins rooms the allowed users invite Sokka to and leaves the rest. Off
/// the sync loop: joining waits for a sync to see the room.
fn on_invites(client: &Client, users: Arc<Vec<String>>) {
    client.add_event_handler(
        move |ev: StrippedRoomMemberEvent, room: Room, client: Client| {
            let users = users.clone();
            async move {
                if client.user_id().is_none_or(|me| ev.state_key != me) {
                    return;
                }
                let id = room.room_id().to_owned();
                let welcome = users.iter().any(|u| *u == ev.sender);
                tokio::spawn(async move {
                    let r = if welcome {
                        room.join().await
                    } else {
                        room.leave().await
                    };
                    if let Err(e) = r {
                        eprintln!("sokka: invite to {id}: {e}");
                    }
                });
            }
        },
    );
}

/// Queues text from allowed users in joined rooms, for one worker to answer
/// in order.
fn on_messages(
    client: &Client,
    users: Arc<Vec<String>>,
    queue: mpsc::UnboundedSender<(Room, String)>,
) {
    client.add_event_handler(move |ev: OriginalSyncRoomMessageEvent, room: Room| {
        let (users, queue) = (users.clone(), queue.clone());
        async move {
            if room.state() != RoomState::Joined || !users.iter().any(|u| *u == ev.sender) {
                return;
            }
            if let MessageType::Text(t) = ev.content.msgtype {
                let _ = queue.send((room, t.body));
            }
        }
    });
    client.add_event_handler(
        |ev: OriginalSyncRoomEncryptedEvent, room: Room| async move {
            eprintln!(
                "sokka: could not decrypt {} from {} in {}",
                ev.event_id,
                ev.sender,
                room.room_id()
            );
        },
    );
}

async fn reply(hippo: Arc<Hippo>, model: Arc<dyn Model>, room: Room, text: String) {
    let _ = room.typing_notice(true).await;
    let reply = tokio::task::spawn_blocking(move || answer(&hippo, model.as_ref(), &text))
        .await
        .unwrap_or_else(|e| Err(e.to_string()))
        .unwrap_or_else(|e| {
            eprintln!("sokka: {e}");
            format!("(I couldn't answer that: {e})")
        });
    let _ = room.typing_notice(false).await;
    if let Err(e) = room.send(RoomMessageEventContent::text_plain(reply)).await {
        eprintln!("sokka: send to {}: {e}", room.room_id());
    }
}

/// Every 30 s, sends the reminders that are due to the room Dylan last
/// wrote from; with no such room yet, they wait.
async fn remind(client: Client, hippo: Arc<Hippo>, state: PathBuf) {
    let mut tick = tokio::time::interval(Duration::from_secs(30));
    loop {
        tick.tick().await;
        let Some(room) = fs::read_to_string(state.join("room"))
            .ok()
            .and_then(|id| OwnedRoomId::try_from(id.trim()).ok())
            .and_then(|id| client.get_room(&id))
        else {
            continue;
        };
        let due = match book::change(&state, |b| b.due(Local::now().naive_local())) {
            Ok(due) => due,
            Err(e) => {
                eprintln!("sokka: {e}");
                continue;
            }
        };
        for r in due {
            let text = format!("Reminder: {}", r.text);
            if let Err(e) = room.send(RoomMessageEventContent::text_plain(&text)).await {
                eprintln!("sokka: reminder {}: {e}", r.id);
                continue;
            }
            let hippo = hippo.clone();
            let logged = tokio::task::spawn_blocking(move || hippo.log("talk", &text)).await;
            if let Ok(Err(e)) = logged {
                eprintln!("sokka: {e}");
            }
        }
    }
}

async fn run() -> Result<(), String> {
    let state = PathBuf::from(var("STATE_DIRECTORY")?);
    let users: Arc<Vec<String>> = Arc::new(
        var("SOKKA_USERS")?
            .split(',')
            .map(|u| u.trim().to_owned())
            .collect(),
    );
    let hippo = Arc::new(Hippo {
        sock: PathBuf::from(var("HIPPO_DIR")?).join("hippo.sock"),
    });
    let model: Arc<dyn Model> = model::from_env()?.into();
    let (client, fresh) = matrix::connect(
        &var("SOKKA_HOMESERVER")?,
        &var("MATRIX_USER")?,
        &var("MATRIX_PASSWORD")?,
        &state.join("matrix"),
    )
    .await?;

    on_invites(&client, users.clone());
    if fresh {
        client
            .sync_once(SyncSettings::default())
            .await
            .map_err(|e| format!("sync: {e}"))?;
    }
    let (queue, mut inbox) = mpsc::unbounded_channel();
    on_messages(&client, users, queue);
    tokio::spawn(remind(client.clone(), hippo.clone(), state.clone()));
    tokio::spawn(async move {
        while let Some((room, text)) = inbox.recv().await {
            if let Err(e) = fs::write(state.join("room"), room.room_id().as_str()) {
                eprintln!("sokka: room: {e}");
            }
            reply(hippo.clone(), model.clone(), room, text).await;
        }
    });
    eprintln!("sokka: listening");
    client
        .sync(SyncSettings::default())
        .await
        .map_err(|e| format!("sync: {e}"))
}

#[tokio::main]
async fn main() -> ExitCode {
    // The homeserver is plain http on loopback, but reqwest panics
    // without a TLS provider installed.
    let _ = rustls::crypto::ring::default_provider().install_default();
    let args: Vec<String> = env::args().skip(1).collect();
    let r = match args.as_slice() {
        [] => run().await,
        [cmd, dir] if cmd == "tools" => tools::serve(PathBuf::from(dir)).await,
        _ => Err("usage: sokka [tools DIR]".into()),
    };
    match r {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("sokka: {e}");
            ExitCode::FAILURE
        }
    }
}
