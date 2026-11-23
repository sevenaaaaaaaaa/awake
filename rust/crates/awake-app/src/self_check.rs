//! 设备内自检（S2）：把「不该悄悄坏掉」的纯逻辑逐条钉住。
//!
//! 规矩只有一条：**每条断言里的期望值必须是写死的数字或字面量，不能再去调一次生产函数算。**
//! 否则改坏常量之后两边一起变，永远是绿的——那就不是自检，是复读。
//!
//! 覆盖 v2 点名的五项：曲线限幅、先验叠加、档案解析、依据失效判定、差异文案，
//! 外加 S1 引入的两条（同名不猜、曲目指纹）。
//!
//! 这份清单不检查界面与手势：它全绿只说明纯函数是对的，不说明产品可用。
//! 这句话要原样出现在自检页顶部，不能让人误以为「全绿 = 能听」。

use awake_core::eq::BAND_COUNT;
use awake_core::listening::{
    apply_prior, match_curves, parse_profile, same_device, stale_hint, track_fingerprint, EarPrior,
    ListeningProfile, ProfileError, SongCurve, TrackRef, UnmatchedReason,
};
use std::collections::HashMap;

#[derive(Debug, Clone, serde::Serialize)]
pub struct CheckItem {
    pub id: &'static str,
    pub name: &'static str,
    pub ok: bool,
    /// 红了才看得懂差在哪；绿的时候为空串。
    pub detail: String,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct SelfCheckReport {
    pub version: &'static str,
    pub checked_at: String,
    pub items: Vec<CheckItem>,
    pub passed: usize,
    pub total: usize,
}

struct Case {
    id: &'static str,
    name: &'static str,
    run: fn() -> Result<(), String>,
}

fn near(actual: f32, expected: f32, what: &str) -> Result<(), String> {
    if (actual - expected).abs() < 1e-4 {
        Ok(())
    } else {
        Err(format!("{what}：期望 {expected}，实际 {actual}"))
    }
}

fn track(id: &str, title: &str) -> TrackRef {
    TrackRef {
        id: id.to_string(),
        title: title.to_string(),
        artist: "自检".to_string(),
        duration: 200.0,
    }
}

fn check_prior_clamp() -> Result<(), String> {
    let gains = [10.0f32; BAND_COUNT];
    let prior = EarPrior {
        version: 7,
        gains: [5.0f32; BAND_COUNT],
        ..Default::default()
    };
    let out = apply_prior(&gains, Some(&prior), true);
    near(out[0], 12.0, "10 + 5 应被限幅到 12")?;
    near(out[BAND_COUNT - 1], 12.0, "末段也要限幅")
}

fn check_prior_off() -> Result<(), String> {
    let gains = [10.0f32; BAND_COUNT];
    let prior = EarPrior {
        version: 7,
        gains: [5.0f32; BAND_COUNT],
        ..Default::default()
    };
    let out = apply_prior(&gains, Some(&prior), false);
    near(out[0], 10.0, "关掉叠加应原样返回")
}

fn check_prior_absent() -> Result<(), String> {
    let gains = [-3.0f32; BAND_COUNT];
    let out = apply_prior(&gains, None, true);
    near(out[0], -3.0, "没有先验时不应改动曲线")
}

fn check_profile_parse() -> Result<(), String> {
    let good = vec!["0"; BAND_COUNT].join(",");
    let json = format!(
        r#"{{"version":1,"device":"check","curves":{{"A":{{"gains":[{good}]}},"B":{{"gains":[1,2]}}}},"titles":{{"A":"好","B":"坏"}}}}"#
    );
    let profile = parse_profile(&json).map_err(|error| error.to_string())?;
    if profile.curves.len() != 1 {
        return Err(format!(
            "应只留下 1 条合法曲线，实际 {}",
            profile.curves.len()
        ));
    }
    if profile.rejected.len() != 1 {
        return Err(format!(
            "应记录 1 条坏曲线，实际 {}",
            profile.rejected.len()
        ));
    }
    Ok(())
}

fn check_profile_version() -> Result<(), String> {
    let json = r#"{"version":9,"curves":{},"titles":{}}"#;
    match parse_profile(json) {
        Err(ProfileError::UnsupportedVersion(9)) => Ok(()),
        other => Err(format!("版本 9 应被拒绝，实际 {other:?}")),
    }
}

fn check_match_ambiguous() -> Result<(), String> {
    let mut titles = HashMap::new();
    titles.insert("A".to_string(), "夜航".to_string());
    let mut curves = HashMap::new();
    curves.insert("A".to_string(), SongCurve::default());
    let profile = ListeningProfile {
        version: 1,
        titles,
        curves,
        ..Default::default()
    };
    let report = match_curves(&profile, &[track("1", "夜航"), track("2", "夜航")]);
    if !report.matched.is_empty() {
        return Err("同名多首不该自动选一首".into());
    }
    match report.unmatched.first().map(|item| &item.reason) {
        Some(UnmatchedReason::Ambiguous { candidates: 2 }) => Ok(()),
        other => Err(format!("应报「同名 2 首」，实际 {other:?}")),
    }
}

fn check_device_rules() -> Result<(), String> {
    if !same_device("AirPods Pro", "airpods pro") {
        return Err("只差大小写不该判失效".into());
    }
    if same_device("AirPods Pro", "监听耳机") {
        return Err("不同耳机必须判失效".into());
    }
    if !same_device("", "AirPods Pro") {
        return Err("不知道保存的是哪副时不该判失效".into());
    }
    Ok(())
}

fn check_stale_hint() -> Result<(), String> {
    let hint = stale_hint("AirPods Pro", "监听耳机");
    if !hint.contains("AirPods Pro") || !hint.contains("监听耳机") {
        return Err(format!("文案要同时点名两边，实际「{hint}」"));
    }
    if !stale_hint("AirPods Pro", "airpods pro").is_empty() {
        return Err("依据成立时不该有提示".into());
    }
    Ok(())
}

fn check_fingerprint() -> Result<(), String> {
    let value = track_fingerprint(222.0, 44100, "夜航", "");
    if value != "3:42 · 44 kHz · 夜航" {
        return Err(format!("期望「3:42 · 44 kHz · 夜航」，实际「{value}」"));
    }
    Ok(())
}

const CASES: &[Case] = &[
    Case {
        id: "prior.clamp",
        name: "先验叠加先加后限幅（10 + 5 → 12）",
        run: check_prior_clamp,
    },
    Case {
        id: "prior.off",
        name: "关掉先验时曲线原样",
        run: check_prior_off,
    },
    Case {
        id: "prior.absent",
        name: "没有先验时曲线原样",
        run: check_prior_absent,
    },
    Case {
        id: "profile.parse",
        name: "档案解析：坏的跳过、好的留下",
        run: check_profile_parse,
    },
    Case {
        id: "profile.version",
        name: "未知档案版本必须拒绝",
        run: check_profile_version,
    },
    Case {
        id: "curves.ambiguous",
        name: "同名多首不自动选",
        run: check_match_ambiguous,
    },
    Case {
        id: "basis.device",
        name: "依据失效判定（大小写容忍、换耳机失效）",
        run: check_device_rules,
    },
    Case {
        id: "basis.hint",
        name: "失效文案要点名两边",
        run: check_stale_hint,
    },
    Case {
        id: "basis.fingerprint",
        name: "曲目依据指纹写法（3:42 · 44 kHz）",
        run: check_fingerprint,
    },
];

fn iso_now() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

fn run_cases(cases: &[Case]) -> SelfCheckReport {
    let mut items = Vec::with_capacity(cases.len());
    for case in cases {
        let outcome = (case.run)();
        items.push(CheckItem {
            id: case.id,
            name: case.name,
            ok: outcome.is_ok(),
            detail: outcome.err().unwrap_or_default(),
        });
    }
    let passed = items.iter().filter(|item| item.ok).count();
    SelfCheckReport {
        version: env!("CARGO_PKG_VERSION"),
        checked_at: iso_now(),
        passed,
        total: items.len(),
        items,
    }
}

/// 设备内自检：返回逐条 PASS/FAIL，不依赖播放、不依赖网络。
#[tauri::command]
pub fn self_check() -> SelfCheckReport {
    run_cases(CASES)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_check_passes_on_a_healthy_build() {
        let report = run_cases(CASES);
        let failed: Vec<String> = report
            .items
            .iter()
            .filter(|item| !item.ok)
            .map(|item| format!("{}（{}）：{}", item.id, item.name, item.detail))
            .collect();
        assert!(
            failed.is_empty(),
            "自检有红项：\n{}",
            failed.join("\n")
        );
        assert_eq!(report.passed, report.total);
        assert_eq!(report.total, 9, "清单条数变了要在这里同步，免得悄悄少测");
    }

    #[test]
    fn a_broken_case_really_turns_red() {
        // 这条测的是「自检机制本身会红」，不是某个功能。
        fn broken() -> Result<(), String> {
            Err("期望 12，实际 6".to_string())
        }
        let report = run_cases(&[Case {
            id: "fake",
            name: "故意错的",
            run: broken,
        }]);
        assert_eq!(report.passed, 0);
        assert!(!report.items[0].ok);
        assert!(report.items[0].detail.contains("期望 12"));
    }
}
