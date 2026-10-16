//! Weather from Open-Meteo, which needs no key: now and the next few days
//! for one place, in °F.

use serde::{Deserialize, Serialize};
use std::time::Duration;
use ureq::Agent;

const DAYS: u32 = 5;

pub struct Weather {
    url: String,
    agent: Agent,
}

/// What the page draws. `code` is the WMO weather code Open-Meteo uses.
#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct Report {
    pub now: Now,
    pub days: Vec<Day>,
}

#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct Now {
    pub temp: f64,
    pub feels: f64,
    pub code: u8,
    pub day: bool,
}

#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct Day {
    pub date: String,
    pub code: u8,
    pub high: f64,
    pub low: f64,
    pub rain: Option<u8>,
}

#[derive(Deserialize)]
struct Answer {
    current: Current,
    daily: Daily,
}

#[derive(Deserialize)]
struct Current {
    temperature_2m: f64,
    apparent_temperature: f64,
    weather_code: u8,
    is_day: u8,
}

#[derive(Deserialize)]
struct Daily {
    time: Vec<String>,
    weather_code: Vec<u8>,
    temperature_2m_max: Vec<f64>,
    temperature_2m_min: Vec<f64>,
    precipitation_probability_max: Vec<Option<u8>>,
}

impl Weather {
    /// For a place given as `latitude,longitude`, days in zone `zone`.
    pub fn new(place: &str, zone: &str) -> Result<Self, String> {
        let (lat, lon) = place
            .split_once(',')
            .and_then(|(a, b)| Some((a.trim().parse::<f64>().ok()?, b.trim().parse::<f64>().ok()?)))
            .ok_or("FRAME_WEATHER is latitude,longitude")?;
        let url = format!(
            "https://api.open-meteo.com/v1/forecast?latitude={lat}&longitude={lon}\
             &current=temperature_2m,apparent_temperature,weather_code,is_day\
             &daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max\
             &temperature_unit=fahrenheit&timezone={zone}&forecast_days={DAYS}"
        );
        let agent = Agent::config_builder()
            .timeout_global(Some(Duration::from_secs(30)))
            .build()
            .into();
        Ok(Weather { url, agent })
    }

    pub fn report(&self) -> Result<Report, String> {
        let answer: Answer = self
            .agent
            .get(&self.url)
            .call()
            .and_then(|mut r| r.body_mut().read_json())
            .map_err(|e| format!("weather: {e}"))?;
        Ok(read(answer))
    }
}

fn read(a: Answer) -> Report {
    let d = a.daily;
    let days = (0..d.time.len())
        .filter_map(|i| {
            Some(Day {
                date: d.time.get(i)?.clone(),
                code: *d.weather_code.get(i)?,
                high: *d.temperature_2m_max.get(i)?,
                low: *d.temperature_2m_min.get(i)?,
                rain: d.precipitation_probability_max.get(i).copied().flatten(),
            })
        })
        .collect();
    Report {
        now: Now {
            temp: a.current.temperature_2m,
            feels: a.current.apparent_temperature,
            code: a.current.weather_code,
            day: a.current.is_day == 1,
        },
        days,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_answer_reads_into_now_and_days() {
        let a: Answer = serde_json::from_str(
            r#"{"current":{"time":"2026-10-16T14:00","temperature_2m":58.3,"apparent_temperature":55.1,"weather_code":2,"is_day":1},
                "daily":{"time":["2026-10-16","2026-10-17"],"weather_code":[2,61],"temperature_2m_max":[61.0,55.2],"temperature_2m_min":[44.1,47.0],"precipitation_probability_max":[5,null]}}"#,
        )
        .unwrap();
        let r = read(a);
        assert_eq!(r.now.code, 2);
        assert!(r.now.day);
        assert_eq!(r.days.len(), 2);
        assert_eq!(r.days[1].code, 61);
        assert_eq!(r.days[1].rain, None);
    }
}
