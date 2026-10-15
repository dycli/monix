//! Web Push: notifications on the person's phone and desktop when the
//! web door says something, the way a chat app rings. A device subscribes
//! from the page (the bell); its browser hands us an endpoint at its push
//! service (Google's for Chrome, Mozilla's, Apple's) and the keys to
//! encrypt for it. We sign each push with our own VAPID key, made on first
//! start and kept in the state directory: it names this server to the push
//! services, and losing it only means each device subscribes again, which
//! the page does by itself.
//!
//! The service worker (`site/public/sw.js`) shows the notification, or
//! skips it when the app is already on screen.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use serde::Serialize;
use ureq::Agent;
use web_push_native::WebPushBuilder;
use web_push_native::jwt_simple::algorithms::{ECDSAP256KeyPairLike, ES256KeyPair};

/// How long a push service keeps trying a device that is off: a reminder
/// a day late is still worth seeing, one a week late is not.
const TTL: Duration = Duration::from_secs(24 * 60 * 60);
const TIMEOUT: Duration = Duration::from_secs(20);
/// Push services take 4 KB of payload; the notification shows a few lines.
const BODY_MAX: usize = 300;

pub struct Push {
    key: ES256KeyPair,
    /// The site's address: names this server to push services that need to
    /// reach someone about it.
    contact: String,
    /// The notifications' title, the name the installed app goes by.
    pub title: String,
    file: PathBuf,
    /// The devices, as each browser's subscription JSON.
    devices: Mutex<Vec<serde_json::Value>>,
    agent: Agent,
}

/// What the service worker shows.
#[derive(Serialize)]
pub struct Note<'a> {
    pub title: &'a str,
    pub body: String,
    /// Notifications with one tag replace each other, so a burst of
    /// messages leaves one notification, the latest.
    pub tag: &'a str,
}

impl Push {
    /// Loads or makes the key in `dir`, and the devices subscribed so far,
    /// for the site at `url`.
    pub fn load(dir: &Path, url: &str) -> Result<Self, String> {
        let key_file = dir.join("vapid");
        let key = match fs::read_to_string(&key_file) {
            Ok(b64) => URL_SAFE_NO_PAD
                .decode(b64.trim())
                .map_err(|e| e.to_string())
                .and_then(|b| ES256KeyPair::from_bytes(&b).map_err(|e| e.to_string()))
                .map_err(|e| format!("{}: {e}", key_file.display()))?,
            Err(_) => {
                let key = ES256KeyPair::generate();
                crate::site::write_private(&key_file, &URL_SAFE_NO_PAD.encode(key.to_bytes()))?;
                key
            }
        };
        let file = dir.join("push.json");
        let devices = fs::read_to_string(&file)
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_default();
        let config = Agent::config_builder()
            .timeout_global(Some(TIMEOUT))
            .http_status_as_error(false)
            .build();
        Ok(Self {
            key,
            contact: url.into(),
            title: crate::site::name_of(url.trim_start_matches("https://")),
            file,
            devices: Mutex::new(devices),
            agent: Agent::new_with_config(config),
        })
    }

    /// The public key the page subscribes with, as the browser takes it.
    pub fn public(&self) -> String {
        URL_SAFE_NO_PAD.encode(self.key.key_pair().public_key().to_bytes_uncompressed())
    }

    /// Adds a device, or refreshes it when it subscribed before.
    pub fn subscribe(&self, sub: serde_json::Value) -> Result<(), String> {
        serde_json::from_value::<WebPushBuilder>(sub.clone())
            .map_err(|e| format!("subscription: {e}"))?;
        let mut devices = self.devices.lock().unwrap();
        devices.retain(|d| d["endpoint"] != sub["endpoint"]);
        devices.push(sub);
        self.save(&devices)
    }

    pub fn unsubscribe(&self, endpoint: &str) -> Result<(), String> {
        let mut devices = self.devices.lock().unwrap();
        devices.retain(|d| d["endpoint"] != endpoint);
        self.save(&devices)
    }

    fn save(&self, devices: &[serde_json::Value]) -> Result<(), String> {
        let text = serde_json::to_string(devices).map_err(|e| e.to_string())?;
        crate::site::write_private(&self.file, &text)
    }

    /// Sends `note` to every device; blocking. A device its push service
    /// no longer knows (404, 410) is dropped, as the protocol asks.
    pub fn send(&self, note: &Note) {
        let devices = self.devices.lock().unwrap().clone();
        if devices.is_empty() {
            return;
        }
        let body = match serde_json::to_vec(note) {
            Ok(b) => b,
            Err(e) => return eprintln!("push: {e}"),
        };
        for d in devices {
            match self.one(&d, &body) {
                Ok(404 | 410) => {
                    let gone = d["endpoint"].as_str().unwrap_or_default();
                    if let Err(e) = self.unsubscribe(gone) {
                        eprintln!("push: {e}");
                    }
                }
                Ok(s) if s >= 300 => eprintln!("push: {} answered {s}", host(&d)),
                Ok(_) => {}
                Err(e) => eprintln!("push: {}: {e}", host(&d)),
            }
        }
    }

    fn one(&self, device: &serde_json::Value, body: &[u8]) -> Result<u16, String> {
        let builder: WebPushBuilder =
            serde_json::from_value(device.clone()).map_err(|e| e.to_string())?;
        let req = builder
            .with_valid_duration(TTL)
            .with_vapid(&self.key, &self.contact)
            .build(body.to_vec())
            .map_err(|e| e.to_string())?;
        let resp = self.agent.run(req).map_err(|e| e.to_string())?;
        Ok(resp.status().as_u16())
    }
}

/// The push service's host, for logs: the endpoint's path names the device.
fn host(device: &serde_json::Value) -> String {
    let url = device["endpoint"].as_str().unwrap_or_default();
    url.split('/').take(3).collect::<Vec<_>>().join("/")
}

/// A message as a notification's few lines: the words without markdown's
/// marks, cut at a word near `BODY_MAX`.
pub fn gist(text: &str) -> String {
    let plain: String = text
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .filter(|c| !matches!(c, '*' | '_' | '`' | '#' | '>'))
        .collect();
    if plain.chars().count() <= BODY_MAX {
        return plain;
    }
    let cut: String = plain.chars().take(BODY_MAX).collect();
    let cut = cut.rsplit_once(' ').map_or(cut.as_str(), |(a, _)| a);
    format!("{cut}…")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gist_drops_marks_and_cuts_at_a_word() {
        assert_eq!(
            gist("**Top story:**  prices\nran `hot`"),
            "Top story: prices ran hot"
        );
        let long = "word ".repeat(100);
        let g = gist(&long);
        assert!(g.ends_with("word…") && g.chars().count() <= BODY_MAX + 1);
    }

    #[test]
    fn key_survives_a_restart_and_devices_are_kept() {
        let dir = std::env::temp_dir().join(format!("yeoman-push-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let a = Push::load(&dir, "https://sokka.example.com").unwrap();
        a.subscribe(serde_json::json!({
            "endpoint": "https://push.example.com/abc",
            "keys": {
                "p256dh": "BLn9b-VR0ca83knDNZ32dCHGyjJp-1riX9ZTN40MqV8K_LpQmLqxC_DoHvqvFXO_nGdAB4W9dogZb_sM-uV4JbY",
                "auth": "_ordMnz7uTCmrpBTeUV4Bw"
            }
        }))
        .unwrap();
        assert!(a.subscribe(serde_json::json!({"endpoint": "x"})).is_err());
        let b = Push::load(&dir, "https://sokka.example.com").unwrap();
        assert_eq!(a.public(), b.public());
        assert_eq!(b.title, "Sokka");
        assert_eq!(b.devices.lock().unwrap().len(), 1);
        b.unsubscribe("https://push.example.com/abc").unwrap();
        assert!(b.devices.lock().unwrap().is_empty());
        fs::remove_dir_all(&dir).unwrap();
    }
}
