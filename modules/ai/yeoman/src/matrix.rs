//! The yeoman's Matrix door, end-to-end encrypted. matrix-sdk keeps room
//! state and the device's keys in a sqlite store under the state directory,
//! with the login beside it, so a restart resumes the same device and the
//! sync picks up where it stopped.

use crate::door::{Door, Fetched, Message};
use crate::{pending, seen};
use matrix_sdk::attachment::AttachmentConfig;
use matrix_sdk::authentication::matrix::MatrixSession;
use matrix_sdk::config::SyncSettings;
use matrix_sdk::encryption::EncryptionSettings;
use matrix_sdk::media::{MediaFormat, MediaRequestParameters};
use matrix_sdk::ruma::api::error::ErrorKind;
use matrix_sdk::ruma::events::reaction::{OriginalSyncReactionEvent, ReactionEventContent};
use matrix_sdk::ruma::events::relation::Annotation;
use matrix_sdk::ruma::events::room::MediaSource;
use matrix_sdk::ruma::events::room::encrypted::OriginalSyncRoomEncryptedEvent;
use matrix_sdk::ruma::events::room::member::StrippedRoomMemberEvent;
use matrix_sdk::ruma::events::room::message::{
    MessageType, OriginalSyncRoomMessageEvent, RoomMessageEventContent,
};
use matrix_sdk::ruma::{OwnedEventId, OwnedRoomId};
use matrix_sdk::store::RoomLoadSettings;
use matrix_sdk::{Client, Room, RoomState};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::sync::mpsc;

async fn client(homeserver: &str, store: &Path) -> Result<Client, String> {
    Client::builder()
        .homeserver_url(homeserver)
        .sqlite_store(store, None)
        .with_encryption_settings(EncryptionSettings {
            // A device signed by the yeoman's own identity, so clients that
            // refuse unsigned devices still share room keys with it.
            auto_enable_cross_signing: true,
            ..Default::default()
        })
        .build()
        .await
        .map_err(|e| format!("matrix client: {e}"))
}

/// A fresh device: the store belongs to the old one, so it goes first.
async fn login(homeserver: &str, user: &str, password: &str, dir: &Path) -> Result<Client, String> {
    let _ = fs::remove_dir_all(dir);
    fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let client = client(homeserver, &dir.join("store")).await?;
    client
        .matrix_auth()
        .login_username(user, password)
        .initial_device_display_name(
            &std::env::var("YEOMAN_NAME").map_err(|_| "YEOMAN_NAME is not set")?,
        )
        .send()
        .await
        .map_err(|e| format!("login: {e}"))?;
    let session = client
        .matrix_auth()
        .session()
        .ok_or("login left no session")?;
    let raw = serde_json::to_string(&session).map_err(|e| e.to_string())?;
    fs::write(dir.join("session.json"), raw).map_err(|e| format!("session.json: {e}"))?;
    eprintln!("yeoman: logged in as a new device");
    Ok(client)
}

async fn restore(homeserver: &str, dir: &Path) -> Result<Option<Client>, String> {
    let Ok(raw) = fs::read_to_string(dir.join("session.json")) else {
        return Ok(None);
    };
    let session: MatrixSession =
        serde_json::from_str(&raw).map_err(|e| format!("session.json: {e}"))?;
    let client = client(homeserver, &dir.join("store")).await?;
    client
        .matrix_auth()
        .restore_session(session, RoomLoadSettings::default())
        .await
        .map_err(|e| format!("restore session: {e}"))?;
    Ok(Some(client))
}

/// A logged-in client, and whether it is a new device (whose first sync
/// should skip the rooms' history).
async fn connect(
    homeserver: &str,
    user: &str,
    password: &str,
    dir: &Path,
) -> Result<(Client, bool), String> {
    if let Some(client) = restore(homeserver, dir).await? {
        match client.whoami().await {
            Ok(_) => return Ok((client, false)),
            Err(e)
                if matches!(
                    e.client_api_error_kind(),
                    Some(ErrorKind::UnknownToken { .. })
                ) =>
            {
                eprintln!("yeoman: the server forgot this device; logging in again");
            }
            Err(e) => return Err(format!("whoami: {e}")),
        }
    }
    Ok((login(homeserver, user, password, dir).await?, true))
}

/// A joined room: the person's door.
#[derive(Clone)]
pub struct Matrix(Room);

/// A photo or file someone sent, not yet downloaded.
pub struct File {
    name: String,
    photo: bool,
    mime: Option<String>,
    source: MediaSource,
    /// A smaller copy, for a photo too big for the model.
    thumbnail: Option<MediaSource>,
}

impl Door for Matrix {
    type File = File;

    async fn say(&self, text: &str) -> Result<String, String> {
        self.send(RoomMessageEventContent::text_markdown(text))
            .await
    }

    async fn quote(&self, text: &str) -> Result<String, String> {
        self.send(RoomMessageEventContent::text_plain(text)).await
    }

    async fn react(&self, to: &str, emoji: &str) -> Result<(), String> {
        let to = OwnedEventId::try_from(to).map_err(|e| e.to_string())?;
        self.0
            .send(ReactionEventContent::new(Annotation::new(
                to,
                emoji.to_owned(),
            )))
            .await
            .map(|_| ())
            .map_err(|e| format!("send to {}: {e}", self.0.room_id()))
    }

    async fn picture(&self, name: &str, data: Vec<u8>, mime: &'static str) -> Result<(), String> {
        let kind: mime::Mime = mime.parse().map_err(|e| format!("{mime}: {e}"))?;
        self.0
            .send_attachment(name, &kind, data, AttachmentConfig::new())
            .await
            .map(|_| ())
            .map_err(|e| e.to_string())
    }

    async fn file(&self, name: &str, data: Vec<u8>, mime: &str) -> Result<(), String> {
        let kind: mime::Mime = mime.parse().unwrap_or(mime::APPLICATION_OCTET_STREAM);
        self.0
            .send_attachment(name, &kind, data, AttachmentConfig::new())
            .await
            .map(|_| ())
            .map_err(|e| e.to_string())
    }

    async fn typing(&self, on: bool) {
        let _ = self.0.typing_notice(on).await;
    }

    /// Downloads and decrypts a file, falling back to a photo's thumbnail
    /// when the original is too big.
    async fn fetch(&self, file: &File) -> Result<Fetched, String> {
        let client = self.0.client();
        let get = |source: &MediaSource| {
            let request = MediaRequestParameters {
                source: source.clone(),
                format: MediaFormat::File,
            };
            let client = client.clone();
            async move { client.media().get_media_content(&request, false).await }
        };
        let data = get(&file.source)
            .await
            .map_err(|e| format!("I couldn't download {}: {e}", file.name))?;
        // A photo too big to see is seen by its thumbnail, and kept whole.
        let mut read = seen(&data, file.mime.as_deref());
        if read.is_none()
            && let Some(thumb) = &file.thumbnail
            && let Ok(small) = get(thumb).await
        {
            read = seen(&small, None);
        }
        Ok(Fetched {
            name: file.name.clone(),
            photo: file.photo,
            data,
            read,
        })
    }
}

impl Matrix {
    async fn send(&self, content: RoomMessageEventContent) -> Result<String, String> {
        self.0
            .send(content)
            .await
            .map(|r| r.response.event_id.to_string())
            .map_err(|e| format!("send to {}: {e}", self.0.room_id()))
    }
}

/// The room the person last wrote from, if any: where reminders, alerts
/// and tasks go.
pub fn last(client: &Client, state: &Path) -> Option<Matrix> {
    fs::read_to_string(state.join("room"))
        .ok()
        .and_then(|id| OwnedRoomId::try_from(id.trim()).ok())
        .and_then(|id| client.get_room(&id))
        .map(Matrix)
}

/// A 👍 or 👎 from an allowed user on a message: the door, the message's
/// id, and yes or no.
pub type Verdict = (Matrix, String, bool);

/// Logs in and starts listening: joins rooms the allowed users invite it
/// to, and passes on what they write and their verdicts on shown acts once
/// `sync` runs.
pub async fn open(
    homeserver: &str,
    (user, password): (String, String),
    state: &Path,
    users: Arc<Vec<String>>,
    messages: mpsc::UnboundedSender<(Matrix, Message<Matrix>)>,
    verdicts: mpsc::UnboundedSender<Verdict>,
) -> Result<Client, String> {
    let (client, fresh) = connect(homeserver, &user, &password, &state.join("matrix")).await?;
    on_invites(&client, users.clone());
    if fresh {
        client
            .sync_once(SyncSettings::default())
            .await
            .map_err(|e| format!("sync: {e}"))?;
    }
    on_messages(&client, users.clone(), state.to_owned(), messages);
    on_reactions(&client, users, verdicts);
    Ok(client)
}

/// Syncs for good.
pub async fn sync(client: &Client) -> Result<(), String> {
    eprintln!("yeoman: listening");
    client
        .sync(SyncSettings::default())
        .await
        .map_err(|e| format!("sync: {e}"))
}

/// Joins rooms the allowed users invite the yeoman to and leaves the rest. Off
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
                        eprintln!("yeoman: invite to {id}: {e}");
                    }
                });
            }
        },
    );
}

/// Queues text, photos and files from allowed users in joined rooms, for
/// one worker to answer in order, and remembers the room each came from.
fn on_messages(
    client: &Client,
    users: Arc<Vec<String>>,
    state: PathBuf,
    queue: mpsc::UnboundedSender<(Matrix, Message<Matrix>)>,
) {
    client.add_event_handler(move |ev: OriginalSyncRoomMessageEvent, room: Room| {
        let (users, state, queue) = (users.clone(), state.clone(), queue.clone());
        async move {
            if room.state() != RoomState::Joined || !users.iter().any(|u| *u == ev.sender) {
                return;
            }
            let (text, file) = match ev.content.msgtype {
                MessageType::Text(t) => (t.body, None),
                MessageType::Image(i) => (
                    i.caption().unwrap_or_default().to_owned(),
                    Some(File {
                        name: i.filename().to_owned(),
                        photo: true,
                        mime: i.info.as_ref().and_then(|x| x.mimetype.clone()),
                        thumbnail: i.info.as_ref().and_then(|x| x.thumbnail_source.clone()),
                        source: i.source,
                    }),
                ),
                MessageType::File(f) => (
                    f.caption().unwrap_or_default().to_owned(),
                    Some(File {
                        name: f.filename().to_owned(),
                        photo: false,
                        mime: f.info.as_ref().and_then(|x| x.mimetype.clone()),
                        thumbnail: None,
                        source: f.source,
                    }),
                ),
                MessageType::Audio(f) => (
                    f.caption().unwrap_or_default().to_owned(),
                    Some(File {
                        name: f.filename().to_owned(),
                        photo: false,
                        mime: f.info.as_ref().and_then(|x| x.mimetype.clone()),
                        thumbnail: None,
                        source: f.source,
                    }),
                ),
                MessageType::Video(f) => (
                    f.caption().unwrap_or_default().to_owned(),
                    Some(File {
                        name: f.filename().to_owned(),
                        photo: false,
                        mime: f.info.as_ref().and_then(|x| x.mimetype.clone()),
                        thumbnail: None,
                        source: f.source,
                    }),
                ),
                _ => return,
            };
            if let Err(e) = fs::write(state.join("room"), room.room_id().as_str()) {
                eprintln!("yeoman: room: {e}");
            }
            let msg = Message {
                id: ev.event_id.to_string(),
                text,
                files: file.into_iter().collect(),
            };
            let _ = queue.send((Matrix(room), msg));
        }
    });
    client.add_event_handler(
        |ev: OriginalSyncRoomEncryptedEvent, room: Room| async move {
            eprintln!(
                "yeoman: could not decrypt {} from {} in {}",
                ev.event_id,
                ev.sender,
                room.room_id()
            );
        },
    );
}

/// Passes on a 👍 or 👎 from an allowed user. The sender check is the same
/// one messages pass; the model is never in this path.
fn on_reactions(
    client: &Client,
    users: Arc<Vec<String>>,
    verdicts: mpsc::UnboundedSender<Verdict>,
) {
    client.add_event_handler(move |ev: OriginalSyncReactionEvent, room: Room| {
        let (users, verdicts) = (users.clone(), verdicts.clone());
        async move {
            if room.state() != RoomState::Joined || !users.iter().any(|u| *u == ev.sender) {
                return;
            }
            let Some(yes) = pending::verdict(&ev.content.relates_to.key) else {
                return;
            };
            let id = ev.content.relates_to.event_id.to_string();
            let _ = verdicts.send((Matrix(room), id, yes));
        }
    });
}
