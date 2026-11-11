//! Sidecar LRC parsing, including multiple timestamps and global millisecond offsets.
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct Line {
    pub time: f64,
    pub text: String,
}

pub fn parse(input: &str) -> Vec<Line> {
    let offset = input
        .lines()
        .find_map(|line| {
            line.trim()
                .strip_prefix("[offset:")?
                .strip_suffix(']')?
                .trim()
                .parse::<f64>()
                .ok()
        })
        .filter(|v| v.is_finite())
        .unwrap_or(0.0)
        / 1000.0;
    let mut lines = Vec::new();
    for line in input.lines() {
        let mut rest = line.trim().trim_start_matches('\u{feff}');
        let mut times = Vec::new();
        while let Some(tag) = rest.strip_prefix('[') {
            let Some(end) = tag.find(']') else { break };
            let value = &tag[..end];
            rest = &tag[end + 1..];
            let Some((minutes, seconds)) = value.split_once(':') else {
                continue;
            };
            let (Ok(m), Ok(s)) = (minutes.parse::<u32>(), seconds.parse::<f64>()) else {
                continue;
            };
            if s.is_finite() && (0.0..60.0).contains(&s) {
                times.push((m as f64 * 60.0 + s + offset).max(0.0));
            }
        }
        if !rest.trim().is_empty() {
            for time in times {
                lines.push(Line {
                    time,
                    text: rest.trim().to_string(),
                });
            }
        }
    }
    lines.sort_by(|a, b| a.time.total_cmp(&b.time));
    lines
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn multi_timestamps_offset_and_metadata() {
        let lines = parse(
            "[ar:Someone]\n[offset:-500]\n[00:01.50][01:02.250]回声\n[00:00.20]开始\n[00:NaN]bad",
        );
        assert_eq!(lines.len(), 3);
        assert_eq!(lines[0].time, 0.0);
        assert_eq!(lines[1].time, 1.0);
        assert_eq!(lines[2].time, 61.75);
        assert_eq!(lines[1].text, "回声");
    }
}
