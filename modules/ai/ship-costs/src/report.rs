use crate::db::Database;
use crate::go::window_by_minutes;
use crate::model::QuotaSample;
use crate::pricing::PriceBook;
use chrono::{DateTime, Utc};
use std::collections::{BTreeMap, BTreeSet};
use std::error::Error;

#[derive(Default)]
struct ProviderSummary {
    events: usize,
    tokens: i64,
    cost: f64,
    priced_events: usize,
    unknown_models: BTreeSet<String>,
    by_source: BTreeMap<String, f64>,
    by_model: BTreeMap<String, f64>,
    first: Option<i64>,
    last: Option<i64>,
}

pub fn print_report(
    database: &Database,
    prices: &PriceBook,
    days: i64,
) -> Result<(), Box<dyn Error>> {
    if days <= 0 {
        return Err("days must be positive".into());
    }
    let now = Utc::now().timestamp();
    let since = now.saturating_sub(days.saturating_mul(86_400));
    let events = database.events_since(since)?;
    let quotas = database.quotas_since(since)?;
    let date = PriceBook::today();
    let mut summaries: BTreeMap<String, ProviderSummary> = BTreeMap::new();
    for event in &events {
        if !matches!(
            event.provider.as_str(),
            "claude" | "chatgpt" | "opencode-go" | "opencode-zen"
        ) {
            continue;
        }
        if event.total_tokens() == 0 && event.web_searches == 0 {
            continue;
        }
        let summary = summaries.entry(event.provider.clone()).or_default();
        summary.events += 1;
        summary.tokens = summary.tokens.saturating_add(event.total_tokens());
        summary.first = Some(
            summary
                .first
                .map_or(event.timestamp, |old| old.min(event.timestamp)),
        );
        summary.last = Some(
            summary
                .last
                .map_or(event.timestamp, |old| old.max(event.timestamp)),
        );
        match prices.cost(event, &date) {
            Some(cost) => {
                summary.cost += cost;
                summary.priced_events += 1;
                *summary.by_source.entry(event.source.clone()).or_default() += cost;
                *summary.by_model.entry(event.model.clone()).or_default() += cost;
            }
            None => {
                summary.unknown_models.insert(event.model.clone());
            }
        }
    }

    println!("SHIP COSTS — trailing {days} days at current API-equivalent rates");
    println!(
        "Pricing verified {} · local agent usage only · subscriptions bill flat",
        prices.verified
    );
    if summaries.is_empty() {
        println!("\nNo Claude or ChatGPT usage has been collected in this window.");
        return Ok(());
    }

    for provider in ["claude", "chatgpt", "opencode-go", "opencode-zen"] {
        let Some(summary) = summaries.get(provider) else {
            continue;
        };
        let label = match provider {
            "claude" => "CLAUDE",
            "chatgpt" => "CHATGPT",
            "opencode-go" => "OPENCODE GO",
            "opencode-zen" => "OPENCODE ZEN",
            _ => provider,
        };
        let monthly = summary.cost * 30.0 / days as f64;
        println!("\n{label}");
        println!("  API equivalent       ${:.2}", summary.cost);
        if days != 30 {
            println!("  30-day pace          ${monthly:.2}");
        }
        println!(
            "  Recorded             {} events · {} tokens · {} to {}",
            summary.events,
            compact(summary.tokens),
            date_of(summary.first),
            date_of(summary.last)
        );
        let sources = summary
            .by_source
            .iter()
            .map(|(source, cost)| format!("{source} ${cost:.2}"))
            .collect::<Vec<_>>()
            .join(" · ");
        if !sources.is_empty() {
            println!("  Sources              {sources}");
        }
        println!("  Plan value");
        for plan in prices.plans.iter().filter(|plan| plan.provider == provider) {
            println!(
                "    {:<18} ${:>6.2}/mo · {:>5.1}× observed value · {:>4.0}× capacity",
                plan.name,
                plan.monthly_usd,
                monthly / plan.monthly_usd,
                plan.multiple
            );
        }

        if summary.unknown_models.is_empty() {
            println!("  Pricing coverage     100% of events");
        } else {
            println!(
                "  Pricing coverage     {}/{} events; unpriced: {}",
                summary.priced_events,
                summary.events,
                summary
                    .unknown_models
                    .iter()
                    .cloned()
                    .collect::<Vec<_>>()
                    .join(", ")
            );
        }

        print_quota(provider, &quotas);
        match provider {
            "opencode-go" => println!(
                "  Billing evidence     Go quota is direct; Zen balance fallback is not included"
            ),
            "opencode-zen" => {
                println!("  Billing evidence     exact charges require the OpenCode console ledger")
            }
            _ => {}
        }
        print_verdict(provider, monthly, &quotas);
    }
    println!(
        "\nAPI-equivalent value cannot see ordinary claude.ai/chatgpt.com chats. Go quota is direct but rounded; exact Zen balance transactions remain in the OpenCode console."
    );
    Ok(())
}

fn print_quota(provider: &str, quotas: &[QuotaSample]) {
    let provider_quotas = quotas
        .iter()
        .filter(|sample| sample.provider == provider)
        .collect::<Vec<_>>();
    if provider_quotas.is_empty() {
        println!("  Quota evidence       unavailable in local logs");
        return;
    }
    let latest = provider_quotas.iter().max_by_key(|sample| sample.timestamp);
    if let Some(latest) = latest {
        println!("  Observed plan        {}", display_plan(&latest.plan));
    }
    let mut by_window: BTreeMap<i64, Vec<&QuotaSample>> = BTreeMap::new();
    for sample in provider_quotas {
        by_window
            .entry(sample.window_minutes)
            .or_default()
            .push(sample);
    }
    if provider == "opencode-go" {
        for (minutes, samples) in by_window {
            if let Some(latest) = samples.iter().max_by_key(|sample| sample.timestamp) {
                let limit = window_by_minutes(minutes).map_or(0.0, |window| window.limit_usd);
                println!(
                    "  Quota {:<10} {:>5.1}% · ≈${:.2}/${:.0} weighted · resets {} · {}",
                    window_name(minutes),
                    latest.used_percent,
                    limit * latest.used_percent / 100.0,
                    limit,
                    reset_of(latest.resets_at),
                    if latest.limit_reached { "capped" } else { "ok" }
                );
            }
        }
        return;
    }
    for (minutes, samples) in by_window {
        let mut values = samples
            .iter()
            .map(|sample| sample.used_percent)
            .collect::<Vec<_>>();
        values.sort_by(f64::total_cmp);
        let p95_index = ((values.len() as f64 * 0.95).ceil() as usize)
            .saturating_sub(1)
            .min(values.len() - 1);
        let p95 = values[p95_index];
        let peak = values.last().copied().unwrap_or(0.0);
        let hits = samples
            .iter()
            .filter(|sample| sample.limit_reached)
            .map(|sample| sample.resets_at.unwrap_or(sample.timestamp))
            .collect::<BTreeSet<_>>()
            .len();
        println!(
            "  Quota {:<10} p95 {:>5.1}% · peak {:>5.1}% · {} capped windows",
            window_name(minutes),
            p95,
            peak,
            hits
        );
    }
}

fn print_verdict(provider: &str, monthly: f64, quotas: &[QuotaSample]) {
    let provider_quotas = quotas
        .iter()
        .filter(|sample| sample.provider == provider)
        .collect::<Vec<_>>();
    let label = "  Verdict             ";
    if provider == "opencode-zen" {
        println!(
            "{label}pay as you go; compare this estimate with the authoritative Zen console ledger"
        );
        return;
    }
    if provider_quotas.is_empty() {
        if monthly < 20.0 {
            println!(
                "{label}API is cheaper for observed agent use; check app-only value and /usage before changing plans"
            );
        } else {
            println!(
                "{label}a subscription beats API for observed use; tier fit still requires /usage history"
            );
        }
        return;
    }
    let mut values = provider_quotas
        .iter()
        .map(|sample| sample.used_percent)
        .collect::<Vec<_>>();
    values.sort_by(f64::total_cmp);
    let p95_index = ((values.len() as f64 * 0.95).ceil() as usize)
        .saturating_sub(1)
        .min(values.len() - 1);
    let p95 = values[p95_index];
    let hits = provider_quotas
        .iter()
        .filter(|sample| sample.limit_reached)
        .map(|sample| {
            (
                sample.window_minutes,
                sample.resets_at.unwrap_or(sample.timestamp),
            )
        })
        .collect::<BTreeSet<_>>()
        .len();
    if provider == "opencode-go" {
        if hits > 0 {
            println!("{label}a Go limit was reached; requests may be spilling into Zen balance");
        } else {
            println!("{label}Go has direct measured headroom; no current limit is reached");
        }
        return;
    }
    if hits > 0 || p95 >= 90.0 {
        println!("{label}current tier is tight; compare the next tier with overage credits");
    } else if p95 < 75.0 {
        println!("{label}current tier has measured headroom");
    } else {
        println!("{label}current tier fits, with limited headroom");
    }
}

fn date_of(timestamp: Option<i64>) -> String {
    timestamp
        .and_then(|timestamp| DateTime::<Utc>::from_timestamp(timestamp, 0))
        .map(|timestamp| timestamp.format("%Y-%m-%d").to_string())
        .unwrap_or_else(|| "unknown".into())
}

fn reset_of(timestamp: Option<i64>) -> String {
    timestamp
        .and_then(|timestamp| DateTime::<Utc>::from_timestamp(timestamp, 0))
        .map(|timestamp| timestamp.format("%Y-%m-%d %H:%MZ").to_string())
        .unwrap_or_else(|| "unknown".into())
}

fn compact(value: i64) -> String {
    let value = value as f64;
    if value >= 1_000_000_000.0 {
        format!("{:.1}B", value / 1_000_000_000.0)
    } else if value >= 1_000_000.0 {
        format!("{:.1}M", value / 1_000_000.0)
    } else if value >= 1_000.0 {
        format!("{:.1}K", value / 1_000.0)
    } else {
        format!("{value:.0}")
    }
}

fn window_name(minutes: i64) -> String {
    match minutes {
        300 => "5 hours".into(),
        10_080 => "7 days".into(),
        minutes if minutes > 0 && minutes % 1_440 == 0 => format!("{} days", minutes / 1_440),
        minutes => format!("{minutes} min"),
    }
}

fn display_plan(plan: &str) -> String {
    match plan {
        "prolite" => "Pro 5x (prolite)".into(),
        "promax" => "Pro 20x (promax)".into(),
        plan => plan.into(),
    }
}
