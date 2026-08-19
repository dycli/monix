mod collect;
mod db;
mod model;
mod pricing;
mod report;

use crate::collect::collect;
use crate::db::Database;
use crate::pricing::PriceBook;
use std::env;
use std::error::Error;
use std::path::{Path, PathBuf};

fn main() {
    if let Err(error) = run() {
        eprintln!("ship-costs: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn Error>> {
    let home = home_dir()?;
    let mut database = Database::open(state_dir(&home).join("usage.sqlite"))?;
    let prices = PriceBook::load()?;
    let arguments = env::args().skip(1).collect::<Vec<_>>();
    match arguments.first().map(String::as_str) {
        None => {
            run_collect(&mut database, &home, true, true);
            report::print_report(&database, &prices, 30)
        }
        Some("collect") => {
            let quiet = arguments.iter().any(|argument| argument == "--quiet");
            let online = arguments.iter().any(|argument| argument == "--online");
            run_collect(&mut database, &home, quiet, online);
            Ok(())
        }
        Some("report") => {
            let days = parse_days(&arguments[1..])?;
            run_collect(&mut database, &home, true, true);
            report::print_report(&database, &prices, days)
        }
        Some("doctor") => doctor(&database, &prices, &home),
        Some("prices") => {
            print_prices(&prices);
            Ok(())
        }
        Some("help" | "--help" | "-h") => {
            usage();
            Ok(())
        }
        Some(command) => Err(format!("unknown command {command:?}; run ship-costs help").into()),
    }
}

fn run_collect(database: &mut Database, home: &Path, quiet: bool, online: bool) {
    let stats = collect(database, home, online);
    for warning in &stats.warnings {
        eprintln!("ship-costs: warning: {warning}");
    }
    if !quiet {
        println!(
            "Collected {} events and {} quota samples from {} changed files ({} unchanged, {} warnings)",
            stats.events_seen,
            stats.quota_samples_seen,
            stats.scanned_files,
            stats.unchanged_files,
            stats.warnings.len()
        );
    }
}

fn doctor(database: &Database, prices: &PriceBook, home: &Path) -> Result<(), Box<dyn Error>> {
    let (events, quotas, sources) = database.counts()?;
    println!("SHIP COSTS DOCTOR");
    println!("  ledger          {}", database.path.display());
    println!("  schema          1");
    println!("  stored          {events} events · {quotas} quota samples · {sources} source files");
    println!(
        "  pricing         verified {} · {} model rows",
        prices.verified,
        prices.models.len()
    );
    for (name, path) in [
        ("Claude", home.join(".claude/projects")),
        ("Codex", home.join(".codex/sessions")),
        ("Codex archive", home.join(".codex/archived_sessions")),
        ("OpenCode", home.join(".local/share/opencode")),
        (
            "Fleet",
            PathBuf::from(option_env!("SHIP_COSTS_FLEET_DIR").unwrap_or("/var/lib/agents/tasks")),
        ),
    ] {
        println!(
            "  {:<15} {} · {}",
            name,
            if path.exists() { "found" } else { "absent" },
            path.display()
        );
    }
    Ok(())
}

fn print_prices(prices: &PriceBook) {
    println!("PRICING — verified {}", prices.verified);
    for model in &prices.models {
        let until = model
            .until
            .as_deref()
            .map(|until| format!(" through {until}"))
            .unwrap_or_default();
        println!(
            "  {:<8} {:<24} from {}{} · in ${:.3} · cached ${:.3} · out ${:.3} / MTok",
            model.provider,
            model.prefix,
            model.from,
            until,
            model.input,
            model.cached_input,
            model.output
        );
    }
    println!("\nPLANS");
    for plan in &prices.plans {
        println!(
            "  {:<8} {:<18} ${:.2}/month · {:.0}x capacity",
            plan.provider, plan.name, plan.monthly_usd, plan.multiple
        );
    }
    println!("\nSOURCES");
    for source in &prices.sources {
        println!("  {source}");
    }
}

fn parse_days(arguments: &[String]) -> Result<i64, Box<dyn Error>> {
    let mut days = 30;
    let mut index = 0;
    while index < arguments.len() {
        match arguments[index].as_str() {
            "--days" => {
                let value = arguments.get(index + 1).ok_or("--days requires a number")?;
                days = value.parse()?;
                index += 2;
            }
            argument => return Err(format!("unknown report argument {argument:?}").into()),
        }
    }
    Ok(days)
}

fn home_dir() -> Result<PathBuf, Box<dyn Error>> {
    env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| "HOME is not set".into())
}

fn state_dir(home: &Path) -> PathBuf {
    env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".local/state"))
        .join("ship-costs")
}

fn usage() {
    println!(
        "ship-costs — local Claude and ChatGPT subscription-value ledger\n\n\
         Usage:\n  ship-costs\n  ship-costs collect [--quiet] [--online]\n  ship-costs report [--days N]\n  ship-costs doctor\n  ship-costs prices"
    );
}
