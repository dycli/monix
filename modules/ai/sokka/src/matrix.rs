//! Sokka's Matrix connection, end-to-end encrypted. matrix-sdk keeps room
//! state and the device's keys in a sqlite store under the state directory,
//! with the login beside it, so a restart resumes the same device and the
//! sync picks up where it stopped.

use matrix_sdk::Client;
use matrix_sdk::authentication::matrix::MatrixSession;
use matrix_sdk::encryption::EncryptionSettings;
use matrix_sdk::ruma::api::error::ErrorKind;
use matrix_sdk::store::RoomLoadSettings;
use std::fs;
use std::path::Path;

async fn client(homeserver: &str, store: &Path) -> Result<Client, String> {
    Client::builder()
        .homeserver_url(homeserver)
        .sqlite_store(store, None)
        .with_encryption_settings(EncryptionSettings {
            // A device signed by Sokka's own identity, so clients that
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
            &std::env::var("SOKKA_NAME").map_err(|_| "SOKKA_NAME is not set")?,
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
    eprintln!("sokka: logged in as a new device");
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
pub async fn connect(
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
                eprintln!("sokka: the server forgot this device; logging in again");
            }
            Err(e) => return Err(format!("whoami: {e}")),
        }
    }
    Ok((login(homeserver, user, password, dir).await?, true))
}
