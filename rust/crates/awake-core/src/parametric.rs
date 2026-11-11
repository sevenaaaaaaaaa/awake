//! Exact RBJ peaking/shelf filters, imported from user-supplied measurement-based APO files.
use crate::eq::BiquadCoeffs;
use serde::{Deserialize, Serialize};
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize, Default)]
pub enum Kind {
    #[default]
    PK,
    LS,
    HS,
}
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Filter {
    pub kind: Kind,
    pub frequency: f32,
    pub gain_db: f32,
    pub q: f32,
}
impl Default for Filter {
    fn default() -> Self {
        Self {
            kind: Kind::PK,
            frequency: 1000.0,
            gain_db: 0.0,
            q: 0.707,
        }
    }
}
impl Filter {
    pub fn coefficients(&self, rate: f32) -> BiquadCoeffs {
        if self.frequency >= rate * 0.5 {
            return BiquadCoeffs::bypass();
        }
        if self.kind == Kind::PK {
            return BiquadCoeffs::peaking(self.frequency, rate, self.gain_db, self.q);
        }
        let a = 10_f32.powf(self.gain_db / 40.0);
        let w = std::f32::consts::TAU * self.frequency / rate;
        let c = w.cos();
        let alpha = w.sin() / (2.0 * self.q);
        let beta = 2.0 * a.sqrt() * alpha;
        let (b0, b1, b2, a0, a1, a2) = match self.kind {
            Kind::LS => (
                a * ((a + 1.0) - (a - 1.0) * c + beta),
                2.0 * a * ((a - 1.0) - (a + 1.0) * c),
                a * ((a + 1.0) - (a - 1.0) * c - beta),
                (a + 1.0) + (a - 1.0) * c + beta,
                -2.0 * ((a - 1.0) + (a + 1.0) * c),
                (a + 1.0) + (a - 1.0) * c - beta,
            ),
            Kind::HS => (
                a * ((a + 1.0) + (a - 1.0) * c + beta),
                -2.0 * a * ((a - 1.0) + (a + 1.0) * c),
                a * ((a + 1.0) + (a - 1.0) * c - beta),
                (a + 1.0) - (a - 1.0) * c + beta,
                2.0 * ((a - 1.0) - (a + 1.0) * c),
                (a + 1.0) - (a - 1.0) * c - beta,
            ),
            Kind::PK => unreachable!(),
        };
        BiquadCoeffs {
            b0: b0 / a0,
            b1: b1 / a0,
            b2: b2 / a0,
            a1: a1 / a0,
            a2: a2 / a0,
        }
    }
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Profile {
    pub id: String,
    pub name: String,
    pub measurement_source: String,
    pub target: String,
    pub preamp: f32,
    pub filters: Vec<Filter>,
}
pub fn parse(text: &str) -> Result<(f32, Vec<Filter>), String> {
    let mut preamp = 0.0;
    let mut filters = Vec::new();
    for (line_no, line) in text.lines().enumerate() {
        let words: Vec<_> = line
            .split('#')
            .next()
            .unwrap_or("")
            .split_whitespace()
            .collect();
        if words.is_empty() {
            continue;
        }
        let fail = || format!("第 {} 行 EQ 配置无效", line_no + 1);
        if words[0].eq_ignore_ascii_case("Preamp:") {
            preamp = words
                .get(1)
                .ok_or_else(fail)?
                .parse::<f32>()
                .map_err(|_| fail())?;
            continue;
        }
        if !words[0].eq_ignore_ascii_case("Filter") {
            continue;
        }
        if words.iter().any(|s| s.eq_ignore_ascii_case("OFF")) {
            continue;
        }
        let on = words
            .iter()
            .position(|s| s.eq_ignore_ascii_case("ON"))
            .ok_or_else(fail)?;
        let kind = match words.get(on + 1).map(|s| s.to_ascii_uppercase()).as_deref() {
            Some("PK") => Kind::PK,
            Some("LS" | "LSC") => Kind::LS,
            Some("HS" | "HSC") => Kind::HS,
            _ => {
                return Err(format!(
                    "第 {} 行：支持 PK / LS / HS 参数滤波器",
                    line_no + 1
                ))
            }
        };
        let value = |key: &str| -> Result<f32, String> {
            let i = words
                .iter()
                .position(|s| s.eq_ignore_ascii_case(key))
                .ok_or_else(fail)?;
            words
                .get(i + 1)
                .ok_or_else(fail)?
                .parse()
                .map_err(|_| fail())
        };
        let filter = Filter {
            kind,
            frequency: value("Fc")?,
            gain_db: value("Gain")?,
            q: value("Q")?,
        };
        if !filter.frequency.is_finite()
            || !(10.0..=22000.0).contains(&filter.frequency)
            || !filter.gain_db.is_finite()
            || filter.gain_db.abs() > 18.0
            || !filter.q.is_finite()
            || !(0.1..=20.0).contains(&filter.q)
        {
            return Err(fail());
        }
        filters.push(filter);
        if filters.len() > 16 {
            return Err("最多支持 16 个参数滤波器".into());
        }
    }
    if filters.is_empty() || !preamp.is_finite() || !(-40.0..=0.0).contains(&preamp) {
        return Err("配置需要有效滤波器和 -40 到 0 dB 的前级".into());
    }
    Ok((preamp, filters))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn autoeq_center_shelves_keep_their_q_and_response() {
        let (_, filters) = parse("Preamp: -3 dB\nFilter 1: ON LSC Fc 105 Hz Gain -2.3 dB Q 0.70\nFilter 2: ON HSC Fc 10000 Hz Gain -3.8 dB Q 0.70").unwrap();
        assert_eq!(filters[0].kind, Kind::LS);
        assert_eq!(filters[1].kind, Kind::HS);
        assert!(
            (filters[0]
                .coefficients(48000.0)
                .magnitude_db(105.0, 48000.0)
                + 1.15)
                .abs()
                < 0.01
        );
    }
    #[test]
    fn apo_import_has_exact_peaking_response_and_shelf_asymptotes() {
        let(p,filters)=parse("Preamp: -6 dB\nFilter 1: ON PK Fc 1000 Hz Gain 6 dB Q 1\nFilter 2: OFF PK Fc 200 Hz Gain 8 dB Q 1\nFilter 3: ON LS Fc 100 Hz Gain 4 dB Q 0.707").unwrap();
        assert_eq!(p, -6.0);
        assert_eq!(filters.len(), 2);
        assert!(
            (filters[0]
                .coefficients(48000.0)
                .magnitude_db(1000.0, 48000.0)
                - 6.0)
                .abs()
                < 0.01
        );
        assert!((filters[1].coefficients(48000.0).magnitude_db(20.0, 48000.0) - 4.0).abs() < 0.05);
        assert!(parse("Filter 1: ON PK Fc 1000 Hz Gain NaN dB Q 1").is_err());
        assert!(parse("Filter 1: ON UNKNOWN Fc 1000 Hz Gain 1 dB Q 1").is_err());
    }
}
