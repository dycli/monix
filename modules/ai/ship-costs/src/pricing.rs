use crate::model::UsageEvent;
use chrono::Utc;
use serde::Deserialize;
use std::error::Error;

#[derive(Debug, Deserialize)]
pub struct PriceBook {
    pub verified: String,
    pub sources: Vec<String>,
    pub models: Vec<ModelPrice>,
    pub plans: Vec<Plan>,
}

#[derive(Debug, Deserialize)]
pub struct ModelPrice {
    pub provider: String,
    pub prefix: String,
    pub from: String,
    pub until: Option<String>,
    pub input: f64,
    pub cached_input: f64,
    pub cache_write_5m: f64,
    pub cache_write_1h: f64,
    pub output: f64,
    #[serde(default)]
    pub web_search: f64,
    pub long_context_tokens: Option<i64>,
    pub long_input: Option<f64>,
    pub long_cached_input: Option<f64>,
    pub long_cache_write: Option<f64>,
    pub long_output: Option<f64>,
}

#[derive(Debug, Deserialize)]
pub struct Plan {
    pub provider: String,
    pub name: String,
    pub monthly_usd: f64,
    pub multiple: f64,
}

impl PriceBook {
    pub fn load() -> Result<Self, Box<dyn Error>> {
        Ok(serde_json::from_str(include_str!("pricing.json"))?)
    }

    pub fn price_for<'a>(&'a self, event: &UsageEvent, date: &str) -> Option<&'a ModelPrice> {
        let model = event.model.rsplit('/').next().unwrap_or(&event.model);
        self.models
            .iter()
            .filter(|price| {
                price.provider == event.provider
                    && model.starts_with(&price.prefix)
                    && price.from.as_str() <= date
                    && price.until.as_deref().is_none_or(|until| date <= until)
            })
            .max_by_key(|price| price.prefix.len())
    }

    pub fn cost(&self, event: &UsageEvent, date: &str) -> Option<f64> {
        if event.provider == "local" {
            return Some(0.0);
        }
        let price = self.price_for(event, date)?;
        let long = price
            .long_context_tokens
            .is_some_and(|threshold| event.context_tokens > threshold);
        let (input, cached, write_5m, write_1h, output) = if long {
            (
                price.long_input.unwrap_or(price.input),
                price.long_cached_input.unwrap_or(price.cached_input),
                price.long_cache_write.unwrap_or(price.cache_write_5m),
                price.long_cache_write.unwrap_or(price.cache_write_1h),
                price.long_output.unwrap_or(price.output),
            )
        } else {
            (
                price.input,
                price.cached_input,
                price.cache_write_5m,
                price.cache_write_1h,
                price.output,
            )
        };
        Some(
            (event.input_tokens as f64 * input
                + event.cache_read_tokens as f64 * cached
                + event.cache_write_5m_tokens as f64 * write_5m
                + event.cache_write_1h_tokens as f64 * write_1h
                + event.output_tokens as f64 * output)
                / 1_000_000.0
                + event.web_searches as f64 * price.web_search,
        )
    }

    pub fn today() -> String {
        Utc::now().date_naive().to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(model: &str, context: i64) -> UsageEvent {
        UsageEvent {
            provider: "chatgpt".into(),
            model: model.into(),
            input_tokens: 1_000_000,
            output_tokens: 1_000_000,
            context_tokens: context,
            ..UsageEvent::default()
        }
    }

    #[test]
    fn current_and_future_prices_are_date_scoped() {
        let book = PriceBook::load().unwrap();
        let mut sonnet = event("claude-sonnet-5", 0);
        sonnet.provider = "claude".into();
        assert_eq!(book.cost(&sonnet, "2026-08-19"), Some(12.0));
        assert_eq!(book.cost(&sonnet, "2026-09-01"), Some(18.0));
    }

    #[test]
    fn long_context_price_is_per_request() {
        let book = PriceBook::load().unwrap();
        assert_eq!(
            book.cost(&event("gpt-5.6-sol", 200_000), "2026-08-19"),
            Some(35.0)
        );
        assert_eq!(
            book.cost(&event("gpt-5.6-sol", 300_000), "2026-08-19"),
            Some(55.0)
        );
    }

    #[test]
    fn unknown_models_are_not_guessed() {
        let book = PriceBook::load().unwrap();
        assert_eq!(book.cost(&event("gpt-future", 0), "2026-08-19"), None);
    }
}
