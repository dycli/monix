//! Buying history: `tape pull START END [--limit USD] [SYMBOL...]`.
//!
//! The price is asked for first and printed; the download only proceeds
//! when it stays under the limit (default $5), so a typo in the range
//! cannot drain the account. Times are passed to Databento as given:
//! `2026-10-06` or `2026-10-06T13:30`, UTC.

use std::{io, path::Path, time::Duration};

use base64::{Engine, prelude::BASE64_STANDARD};

use crate::{DATASET, archive::Archive, symbols};

const HOST: &str = "https://hist.databento.com/v0";
const DEFAULT_LIMIT: f64 = 5.0;

pub fn pull(root: &Path, key: &str, args: &[&str]) -> Result<(), String> {
    let (start, end, limit, syms) = parse(args)?;
    let syms = if syms.is_empty() { symbols() } else { syms };
    let symbol_list = syms.join(",");
    let query = [
        ("dataset", DATASET),
        ("symbols", symbol_list.as_str()),
        ("schema", "mbo"),
        ("stype_in", "continuous"),
        ("start", start),
        ("end", end),
    ];

    let agent = agent();
    let auth = format!("Basic {}", BASE64_STANDARD.encode(format!("{key}:")));
    let cost: f64 = agent
        .get(format!("{HOST}/metadata.get_cost"))
        .header("Authorization", &auth)
        .query_pairs(query)
        .call()
        .map_err(|e| format!("get_cost: {e}"))?
        .body_mut()
        .read_to_string()
        .map_err(|e| e.to_string())?
        .trim()
        .parse()
        .map_err(|e| format!("get_cost: unreadable price: {e}"))?;
    println!("{DATASET} mbo {symbol_list} {start}..{end}: ${cost:.2}");
    if cost > limit {
        return Err(format!(
            "that is over the ${limit:.2} limit; pass --limit {:.0} to buy it",
            cost.ceil()
        ));
    }

    let archive = Archive::new(root, DATASET);
    let day = chrono::NaiveDate::parse_from_str(&start[..10], "%Y-%m-%d")
        .map_err(|_| format!("start {start}: not a date"))?;
    let stamp = format!("pull-{}-{}", clean(start), clean(end));
    let (mut writer, fresh) = archive.open(day, &stamp).map_err(|e| e.to_string())?;
    let mut response = agent
        .post(format!("{HOST}/timeseries.get_range"))
        .header("Authorization", &auth)
        .send_form(
            query
                .into_iter()
                .chain([("encoding", "dbn"), ("compression", "zstd")]),
        )
        .map_err(|e| format!("get_range: {e}"))?;
    let bytes =
        io::copy(&mut response.body_mut().as_reader(), &mut writer).map_err(|e| e.to_string())?;
    drop(writer);
    let path = fresh.commit().map_err(|e| e.to_string())?;
    println!("{} ({bytes} bytes)", path.display());
    Ok(())
}

/// `START END [--limit USD] [SYMBOL...]` in any order after the two times.
fn parse<'a>(args: &[&'a str]) -> Result<(&'a str, &'a str, f64, Vec<String>), String> {
    let [start, end, rest @ ..] = args else {
        return Err(String::from("pull needs START and END"));
    };
    let mut limit = DEFAULT_LIMIT;
    let mut syms = Vec::new();
    let mut it = rest.iter();
    while let Some(word) = it.next() {
        if *word == "--limit" {
            limit = it
                .next()
                .and_then(|v| v.parse().ok())
                .ok_or("--limit needs a dollar amount")?;
        } else {
            syms.push((*word).to_owned());
        }
    }
    Ok((start, end, limit, syms))
}

/// A time as it can appear in a file name.
fn clean(t: &str) -> String {
    t.chars().filter(|c| c.is_ascii_alphanumeric()).collect()
}

fn agent() -> ureq::Agent {
    let config = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(3600)))
        .build();
    ureq::Agent::new_with_config(config)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_limit_and_symbols_follow_the_range() {
        let (s, e, limit, syms) = parse(&[
            "2026-10-06",
            "2026-10-07",
            "ES.c.0",
            "--limit",
            "12",
            "CL.c.0",
        ])
        .unwrap();
        assert_eq!((s, e, limit), ("2026-10-06", "2026-10-07", 12.0));
        assert_eq!(syms, ["ES.c.0", "CL.c.0"]);
        assert_eq!(
            parse(&["2026-10-06", "2026-10-07"]).unwrap().2,
            DEFAULT_LIMIT
        );
        assert!(parse(&["2026-10-06"]).is_err());
        assert!(parse(&["a", "b", "--limit", "cheap"]).is_err());
        assert_eq!(clean("2026-10-06T13:30"), "20261006T1330");
    }
}
