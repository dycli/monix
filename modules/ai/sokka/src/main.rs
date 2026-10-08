//! Sokka: the household assistant. One endless chat with no sessions: each
//! message from the captain becomes one fresh model call that sees Sokka's
//! prompt, its whole memory (its hippo view) and the new message. Both the
//! message and the answer go into hippo, so the next call remembers them.

mod hippo;
mod matrix;
mod model;

use chrono::Local;
use hippo::Hippo;
use matrix_sdk::config::SyncSettings;
use matrix_sdk::ruma::events::room::encrypted::OriginalSyncRoomEncryptedEvent;
use matrix_sdk::ruma::events::room::member::StrippedRoomMemberEvent;
use matrix_sdk::ruma::events::room::message::{
    MessageType, OriginalSyncRoomMessageEvent, RoomMessageEventContent,
};
use matrix_sdk::{Client, Room, RoomState};
use model::Model;
use std::env;
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;
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
    tokio::spawn(async move {
        while let Some((room, text)) = inbox.recv().await {
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
    match run().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("sokka: {e}");
            ExitCode::FAILURE
        }
    }
}
