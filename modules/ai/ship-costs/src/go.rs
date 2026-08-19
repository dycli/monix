pub struct GoWindow {
    pub name: &'static str,
    pub minutes: i64,
    pub limit_usd: f64,
}

// OpenCode Go limits, verified 2026-08-19:
// https://opencode.ai/docs/go/#usage-limits
// The usage API names these windows but does not return their durations or limits.
pub const GO_WINDOWS: [GoWindow; 3] = [
    GoWindow {
        name: "rolling",
        minutes: 300,
        limit_usd: 12.0,
    },
    GoWindow {
        name: "weekly",
        minutes: 10_080,
        limit_usd: 30.0,
    },
    GoWindow {
        name: "monthly",
        minutes: 43_200,
        limit_usd: 60.0,
    },
];

pub fn window_by_minutes(minutes: i64) -> Option<&'static GoWindow> {
    GO_WINDOWS.iter().find(|window| window.minutes == minutes)
}
