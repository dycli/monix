//! Indoor air from an AirGradient monitor's local API, which needs no key:
//! CO₂, temperature in °F, humidity and fine dust, as the monitor shows
//! them (its compensated readings).

use serde::{Deserialize, Serialize};
use std::time::Duration;
use ureq::Agent;

pub struct Air {
    url: String,
    agent: Agent,
}

/// What the page draws.
#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct Reading {
    pub co2: u32,
    pub temp: f64,
    pub humidity: f64,
    pub pm25: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Measures {
    rco2: u32,
    atmp_compensated: f64,
    rhum_compensated: f64,
    pm02_compensated: f64,
}

impl Air {
    /// For the monitor at `host`, e.g. `192.168.30.191`.
    pub fn new(host: &str) -> Self {
        let agent = Agent::config_builder()
            .timeout_global(Some(Duration::from_secs(10)))
            .build()
            .into();
        Air {
            url: format!("http://{host}/measures/current"),
            agent,
        }
    }

    pub fn reading(&self) -> Result<Reading, String> {
        let m: Measures = self
            .agent
            .get(&self.url)
            .call()
            .and_then(|mut r| r.body_mut().read_json())
            .map_err(|e| format!("air: {e}"))?;
        Ok(read(m))
    }
}

fn read(m: Measures) -> Reading {
    Reading {
        co2: m.rco2,
        temp: m.atmp_compensated * 9.0 / 5.0 + 32.0,
        humidity: m.rhum_compensated,
        pm25: m.pm02_compensated,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn measures_read_into_a_reading() {
        let m: Measures = serde_json::from_str(
            r#"{"pm02":0,"pm02Compensated":3.2,"atmp":19.46,"atmpCompensated":20.0,"rhum":66.43,"rhumCompensated":61.5,"rco2":976,"tvocIndex":10.67,"model":"I-9PSL"}"#,
        )
        .unwrap();
        let r = read(m);
        assert_eq!(r.co2, 976);
        assert!((r.temp - 68.0).abs() < 1e-9);
        assert_eq!(r.humidity, 61.5);
        assert_eq!(r.pm25, 3.2);
    }
}
