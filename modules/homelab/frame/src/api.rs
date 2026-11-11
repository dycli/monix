//! The HTTP API, version 1: each domain's functions as JSON and media, for
//! any UI. Handlers only translate; what a request means lives in the
//! domain's module.
//!
//! - `GET  /api/v1/cameras`: the cameras, `[{id, name, turns}]`.
//! - `GET  /api/v1/cameras/{id}/snapshot.jpg?h=`: the latest frame.
//! - `GET  /api/v1/cameras/{id}/live.mp4`: the live view, fragmented MP4.
//! - `POST /api/v1/cameras/{id}/turn/{left|right|up|down}`: turns it briefly.
//! - `GET  /api/v1/events?camera=&after=&before=&severity=&limit=`: what
//!   the cameras saw, newest first.
//! - `GET  /api/v1/events/{id}`, `…/thumbnail.webp`, `…/clip.mp4`.

use std::io::Read as _;
use std::sync::Arc;

use axum::body::{Body, Bytes};
use axum::extract::{Path, Query, State};
use axum::http::{StatusCode, header};
use axum::response::{IntoResponse, Json, Response};
use serde::Deserialize;

use crate::App;
use crate::cameras::{self, Cameras, Fault, Stream, Way};

/// Runs a blocking domain call off the async workers.
pub async fn blocking<T, F>(f: F) -> Result<T, Fault>
where
    F: FnOnce() -> Result<T, Fault> + Send + 'static,
    T: Send + 'static,
{
    tokio::task::spawn_blocking(f)
        .await
        .unwrap_or_else(|e| Err(Fault::Unavailable(e.to_string())))
}

fn fault(f: Fault) -> Response {
    match f {
        Fault::Unknown(s) => (StatusCode::NOT_FOUND, s).into_response(),
        Fault::Invalid(s) => (StatusCode::BAD_REQUEST, s).into_response(),
        Fault::Unavailable(s) => {
            eprintln!("{s}");
            (StatusCode::BAD_GATEWAY, "unavailable").into_response()
        }
    }
}

fn no_cameras() -> Response {
    StatusCode::NOT_FOUND.into_response()
}

/// The cameras, or None where none are configured.
fn cams(app: &Arc<App>) -> Option<&Cameras> {
    app.cameras.as_ref()
}

pub async fn camera_list(State(app): State<Arc<App>>) -> Response {
    let list = cams(&app).map_or(&[][..], Cameras::list);
    ([(header::CACHE_CONTROL, "no-cache")], Json(list)).into_response()
}

#[derive(Deserialize)]
pub struct Height {
    h: Option<u32>,
}

pub async fn snapshot(
    State(app): State<Arc<App>>,
    Path(id): Path<String>,
    Query(q): Query<Height>,
) -> Response {
    if cams(&app).is_none() {
        return no_cameras();
    }
    let a = app.clone();
    match blocking(move || {
        a.cameras
            .as_ref()
            .expect("checked above")
            .snapshot(&id, q.h)
    })
    .await
    {
        Ok(bytes) => (
            [
                (header::CONTENT_TYPE, "image/jpeg"),
                (header::CACHE_CONTROL, "no-store"),
            ],
            bytes,
        )
            .into_response(),
        Err(f) => fault(f),
    }
}

pub async fn live(State(app): State<Arc<App>>, Path(id): Path<String>) -> Response {
    if cams(&app).is_none() {
        return no_cameras();
    }
    let a = app.clone();
    match blocking(move || a.cameras.as_ref().expect("checked above").live(&id)).await {
        Ok(s) => relay(s, "no-store"),
        Err(f) => fault(f),
    }
}

/// Turns a camera for NUDGE, then stops it unless another move came since.
/// The API and MCP both turn by this.
pub async fn nudge(app: &Arc<App>, id: String, way: Way) -> Result<(), Fault> {
    if cams(app).is_none() {
        return Err(Fault::Unknown("no cameras".into()));
    }
    let (a, i) = (app.clone(), id.clone());
    let this = blocking(move || a.cameras.as_ref().expect("checked above").turn(&i, way)).await?;
    let a = app.clone();
    tokio::spawn(async move {
        tokio::time::sleep(cameras::NUDGE).await;
        let stopped = tokio::task::spawn_blocking(move || {
            a.cameras.as_ref().expect("checked above").stop(&id, this)
        })
        .await;
        match stopped {
            Ok(Err(e)) => eprintln!("{e}"),
            Err(e) => eprintln!("{e}"),
            Ok(Ok(())) => {}
        }
    });
    Ok(())
}

pub async fn turn(
    State(app): State<Arc<App>>,
    Path((id, way)): Path<(String, String)>,
) -> Response {
    let Some(way) = Way::parse(&way) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    match nudge(&app, id, way).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(f) => fault(f),
    }
}

pub async fn events(State(app): State<Arc<App>>, Query(q): Query<cameras::Query>) -> Response {
    if cams(&app).is_none() {
        return no_cameras();
    }
    let a = app.clone();
    match blocking(move || a.cameras.as_ref().expect("checked above").events(&q)).await {
        Ok(list) => ([(header::CACHE_CONTROL, "no-cache")], Json(list)).into_response(),
        Err(f) => fault(f),
    }
}

pub async fn event(State(app): State<Arc<App>>, Path(id): Path<String>) -> Response {
    if cams(&app).is_none() {
        return no_cameras();
    }
    let a = app.clone();
    match blocking(move || a.cameras.as_ref().expect("checked above").event(&id)).await {
        Ok(e) => Json(e).into_response(),
        Err(f) => fault(f),
    }
}

pub async fn thumbnail(State(app): State<Arc<App>>, Path(id): Path<String>) -> Response {
    if cams(&app).is_none() {
        return no_cameras();
    }
    let a = app.clone();
    match blocking(move || a.cameras.as_ref().expect("checked above").thumbnail(&id)).await {
        Ok(bytes) => (
            [
                (header::CONTENT_TYPE, "image/webp"),
                (header::CACHE_CONTROL, "max-age=86400"),
            ],
            bytes,
        )
            .into_response(),
        Err(f) => fault(f),
    }
}

pub async fn clip(State(app): State<Arc<App>>, Path(id): Path<String>) -> Response {
    if cams(&app).is_none() {
        return no_cameras();
    }
    let a = app.clone();
    match blocking(move || a.cameras.as_ref().expect("checked above").clip(&id)).await {
        Ok(s) => relay(s, "max-age=3600"),
        Err(f) => fault(f),
    }
}

/// A body relayed as it arrives. The read blocks, so it runs on its own
/// thread and hands chunks over; when the caller goes away the receiver
/// drops, the send fails and the thread lets go of the source.
fn relay(s: Stream, cache: &'static str) -> Response {
    let (tx, rx) = tokio::sync::mpsc::channel::<Result<Bytes, std::io::Error>>(8);
    let mut body = s.body;
    tokio::task::spawn_blocking(move || {
        let mut buf = vec![0; 64 << 10];
        loop {
            let chunk = match body.read(&mut buf) {
                Ok(0) => return,
                Ok(n) => Ok(Bytes::copy_from_slice(&buf[..n])),
                Err(e) => Err(e),
            };
            let end = chunk.is_err();
            if tx.blocking_send(chunk).is_err() || end {
                return;
            }
        }
    });
    let stream =
        futures_util::stream::unfold(rx, |mut rx| async { rx.recv().await.map(|c| (c, rx)) });
    let mut r = Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, s.kind)
        .header(header::CACHE_CONTROL, cache);
    if let Some(l) = s.length {
        r = r.header(header::CONTENT_LENGTH, l);
    }
    r.body(Body::from_stream(stream))
        .unwrap_or_else(|e| fault(Fault::Unavailable(e.to_string())))
}
