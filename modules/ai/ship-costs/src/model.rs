#[derive(Clone, Debug, Default)]
pub struct UsageEvent {
    pub id: String,
    pub timestamp: i64,
    pub provider: String,
    pub source: String,
    pub model: String,
    pub session: String,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub cache_read_tokens: i64,
    pub cache_write_5m_tokens: i64,
    pub cache_write_1h_tokens: i64,
    pub context_tokens: i64,
    pub web_searches: i64,
}

impl UsageEvent {
    pub fn total_tokens(&self) -> i64 {
        self.input_tokens
            .saturating_add(self.output_tokens)
            .saturating_add(self.cache_read_tokens)
            .saturating_add(self.cache_write_5m_tokens)
            .saturating_add(self.cache_write_1h_tokens)
    }
}

#[derive(Clone, Debug)]
pub struct QuotaSample {
    pub id: String,
    pub timestamp: i64,
    pub provider: String,
    pub plan: String,
    pub window_minutes: i64,
    pub used_percent: f64,
    pub resets_at: Option<i64>,
    pub limit_reached: bool,
}

pub fn provider_of(provider_hint: &str, model: &str) -> &'static str {
    let provider = provider_hint.to_ascii_lowercase();
    let model = model.to_ascii_lowercase();
    if provider == "local" || model.starts_with("local/") {
        "local"
    } else if provider.contains("anthropic") || model.contains("claude") {
        "claude"
    } else if provider.contains("openai") || model.contains("gpt") {
        "chatgpt"
    } else {
        "other"
    }
}
