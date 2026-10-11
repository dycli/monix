//! The ship's market-data tape: records Databento's CME order book to the
//! NAS and reads it back.
//!
//! `tape record` keeps one live session open and writes every record it
//! receives, unaltered, as Zstandard-compressed DBN, one file per UTC day
//! and connection. `tape pull` buys a slice of history into the same shape
//! after showing its price. `tape show` and `tape dump` read a file back.
//!
//! Environment: `TAPE_DIR` (archive root), `TAPE_KEY_FILE` (the API key),
//! `TAPE_SYMBOLS` (comma-separated, continuous-contract notation).

mod archive;
mod history;
mod live;
mod read;

use std::{env, path::PathBuf, process::ExitCode};

const DATASET: &str = "GLBX.MDP3";

fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();
    let words: Vec<&str> = args.iter().map(String::as_str).collect();
    let result = match words.as_slice() {
        ["record"] => live::record(&archive(), &key(), &symbols()),
        ["pull", rest @ ..] => history::pull(&archive(), &key(), rest),
        ["show", file] => read::show(file),
        ["dump", file] => read::dump(file),
        _ => Err(String::from(
            "usage: tape record | pull START END [--limit USD] [SYMBOL...] | show FILE | dump FILE",
        )),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("tape: {e}");
            ExitCode::FAILURE
        }
    }
}

fn archive() -> PathBuf {
    PathBuf::from(env::var("TAPE_DIR").unwrap_or_else(|_| String::from(".")))
}

/// The API key, trimmed, from the file `TAPE_KEY_FILE` names. Never logged.
fn key() -> String {
    let path = env::var("TAPE_KEY_FILE").unwrap_or_else(|_| {
        eprintln!("tape: TAPE_KEY_FILE is not set");
        std::process::exit(2)
    });
    match std::fs::read_to_string(&path) {
        Ok(k) => k.trim().to_owned(),
        Err(e) => {
            eprintln!("tape: {path}: {e}");
            std::process::exit(2)
        }
    }
}

fn symbols() -> Vec<String> {
    env::var("TAPE_SYMBOLS")
        .unwrap_or_else(|_| String::from("ES.c.0,ES.c.1"))
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .collect()
}
