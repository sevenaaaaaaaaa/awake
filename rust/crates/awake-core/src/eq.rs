//! 31 段图形 EQ 与参数 EQ —— Awake 的核心声音处理。
//!
//! 与 Swift 侧 `EQCurve` / `EQBand` 保持数值一致：
//! - 频段为 ISO 1/3 倍频程中心频率（20 Hz … 20 kHz，共 31 段）
//! - 每段是一个 peaking biquad，Q 由 1/3 倍频程带宽推出
//! - headroom 余量 = -(最大提升量) - margin，避免削波

use serde::{Deserialize, Serialize};
use std::f32::consts::PI;

/// ISO 1/3 倍频程中心频率，与 Swift `EQBand.frequencies` 逐项一致。
pub const EQ_BAND_FREQUENCIES: [f32; 31] = [
    20.0, 25.0, 31.5, 40.0, 50.0, 63.0, 80.0, 100.0, 125.0, 160.0, 200.0, 250.0, 315.0, 400.0,
    500.0, 630.0, 800.0, 1000.0, 1250.0, 1600.0, 2000.0, 2500.0, 3150.0, 4000.0, 5000.0, 6300.0,
    8000.0, 10000.0, 12500.0, 16000.0, 20000.0,
];

pub const BAND_COUNT: usize = 31;

/// 1/3 倍频程对应的 Q 值：Q = sqrt(2^(1/3)) / (2^(1/3) - 1) ≈ 4.3185
pub const THIRD_OCTAVE_Q: f32 = 4.318_47;

/// 一段 EQ 修正曲线（dB）+ 前级增益（dB）。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct EqCurve {
    pub gains: [f32; BAND_COUNT],
    pub preamp: f32,
    #[serde(default)]
    pub filters: [crate::parametric::Filter; 16],
    #[serde(default)]
    pub filter_count: usize,
    #[serde(default)]
    pub correction_preamp: f32,
}

impl Default for EqCurve {
    fn default() -> Self {
        Self::flat()
    }
}

impl EqCurve {
    pub fn flat() -> Self {
        Self {
            gains: [0.0; BAND_COUNT],
            preamp: 0.0,
            filters: [crate::parametric::Filter::default(); 16],
            filter_count: 0,
            correction_preamp: 0.0,
        }
    }

    /// 从任意长度增益表构造，超长截断、不足补 0。
    pub fn new(gains: &[f32], preamp: f32) -> Self {
        let mut out = [0.0f32; BAND_COUNT];
        for (i, g) in gains.iter().take(BAND_COUNT).enumerate() {
            out[i] = *g;
        }
        Self {
            gains: out,
            preamp,
            ..Self::flat()
        }
    }

    pub fn is_flat(&self) -> bool {
        self.filter_count == 0
            && self.gains.iter().all(|g| g.abs() < 0.05)
            && self.preamp.abs() < 0.05
    }

    pub fn max_gain(&self) -> f32 {
        self.gains.iter().copied().fold(f32::NEG_INFINITY, f32::max)
    }

    pub fn min_gain(&self) -> f32 {
        self.gains.iter().copied().fold(f32::INFINITY, f32::min)
    }

    pub fn limited(&self, limit: f32) -> Self {
        let mut c = self.clone();
        for g in c.gains.iter_mut() {
            *g = g.clamp(-limit, limit);
        }
        c
    }

    pub fn scaled(&self, factor: f32) -> Self {
        let f = factor.clamp(0.0, 1.4);
        let mut c = self.clone();
        for g in c.gains.iter_mut() {
            *g *= f;
        }
        c.preamp *= f;
        c
    }

    /// 提升多少就压多少前级（含安全余量），等价 Swift `headroomCurve(margin:)`。
    pub fn headroom(&self, margin: f32) -> Self {
        let boost = self.max_gain().max(0.0);
        let mut c = self.clone();
        c.preamp = c.preamp.min(-(boost + margin));
        c
    }

    /// 倾斜：正值变亮、负值变暖，绕 pivot 转。
    pub fn tilted(&self, db_per_octave: f32, pivot: f32) -> Self {
        let mut c = self.clone();
        for (i, f) in EQ_BAND_FREQUENCIES.iter().enumerate() {
            let octaves = ((*f).max(20.0) / pivot).log2();
            c.gains[i] += db_per_octave * octaves;
        }
        c
    }
}

/// 单个 peaking biquad 的系数（已归一化，a0 = 1）。
#[derive(Debug, Clone, Copy)]
pub struct BiquadCoeffs {
    pub b0: f32,
    pub b1: f32,
    pub b2: f32,
    pub a1: f32,
    pub a2: f32,
}

impl BiquadCoeffs {
    /// RBJ Audio EQ Cookbook 的 peaking EQ。
    pub fn peaking(freq: f32, sample_rate: f32, gain_db: f32, q: f32) -> Self {
        // 频率越界时退化为直通，避免 NaN。
        if freq <= 0.0 || freq >= sample_rate * 0.5 || gain_db.abs() < 1e-6 {
            return Self::bypass();
        }
        let a = 10f32.powf(gain_db / 40.0);
        let w0 = 2.0 * PI * freq / sample_rate;
        let cos_w0 = w0.cos();
        let alpha = w0.sin() / (2.0 * q);

        let a0 = 1.0 + alpha / a;
        Self {
            b0: (1.0 + alpha * a) / a0,
            b1: (-2.0 * cos_w0) / a0,
            b2: (1.0 - alpha * a) / a0,
            a1: (-2.0 * cos_w0) / a0,
            a2: (1.0 - alpha / a) / a0,
        }
    }

    pub fn bypass() -> Self {
        Self {
            b0: 1.0,
            b1: 0.0,
            b2: 0.0,
            a1: 0.0,
            a2: 0.0,
        }
    }

    /// 在给定频率处的幅度响应（dB），用于校验曲线是否符合目标。
    pub fn magnitude_db(&self, freq: f32, sample_rate: f32) -> f32 {
        let w = 2.0 * PI * freq / sample_rate;
        let (sin1, cos1) = w.sin_cos();
        let (sin2, cos2) = (2.0 * w).sin_cos();

        let num_re = self.b0 + self.b1 * cos1 + self.b2 * cos2;
        let num_im = -(self.b1 * sin1 + self.b2 * sin2);
        let den_re = 1.0 + self.a1 * cos1 + self.a2 * cos2;
        let den_im = -(self.a1 * sin1 + self.a2 * sin2);

        let num = (num_re * num_re + num_im * num_im).sqrt();
        let den = (den_re * den_re + den_im * den_im).sqrt();
        if den <= 1e-12 {
            return 0.0;
        }
        20.0 * (num / den).log10()
    }
}

/// 一个二阶节的状态（Direct Form I）。
#[derive(Debug, Clone, Copy, Default)]
struct BiquadState {
    x1: f32,
    x2: f32,
    y1: f32,
    y2: f32,
}

impl BiquadState {
    #[inline]
    fn process(&mut self, c: &BiquadCoeffs, x: f32) -> f32 {
        let y = c.b0 * x + c.b1 * self.x1 + c.b2 * self.x2 - c.a1 * self.y1 - c.a2 * self.y2;
        self.x2 = self.x1;
        self.x1 = x;
        self.y2 = self.y1;
        self.y1 = y;
        y
    }

    fn reset(&mut self) {
        *self = Self::default();
    }
}

/// 31 段级联滤波器的运行时实例。每个声道独立状态。
pub struct Equalizer {
    sample_rate: f32,
    channels: usize,
    coeffs: Vec<BiquadCoeffs>,
    preamp_linear: f32,
    active_bands: Vec<usize>,
    states: Vec<BiquadState>,
}

impl Equalizer {
    pub fn new(sample_rate: f32, channels: usize) -> Self {
        Self {
            sample_rate,
            channels,
            coeffs: vec![BiquadCoeffs::bypass(); BAND_COUNT + 16],
            preamp_linear: 1.0,
            active_bands: Vec::with_capacity(BAND_COUNT + 16),
            states: vec![BiquadState::default(); (BAND_COUNT + 16) * channels.max(1)],
        }
    }

    pub fn apply_curve(&mut self, curve: &EqCurve) {
        self.active_bands.clear();
        for (i, freq) in EQ_BAND_FREQUENCIES.iter().enumerate() {
            if curve.gains[i].abs() >= 1e-6 && *freq < self.sample_rate * 0.5 {
                self.active_bands.push(i);
            }
            self.coeffs[i] =
                BiquadCoeffs::peaking(*freq, self.sample_rate, curve.gains[i], THIRD_OCTAVE_Q);
        }
        for i in 0..16 {
            let band = BAND_COUNT + i;
            self.coeffs[band] = if i < curve.filter_count.min(16) {
                curve.filters[i].coefficients(self.sample_rate)
            } else {
                BiquadCoeffs::bypass()
            };
            if i < curve.filter_count.min(16) {
                self.active_bands.push(band);
            }
        }
        self.preamp_linear = 10f32.powf(curve.preamp / 20.0);
    }

    pub fn reset(&mut self) {
        for s in self.states.iter_mut() {
            s.reset();
        }
    }

    /// 就地处理交错排列的 f32 采样（左、右、左、右…）。
    pub fn process_interleaved(&mut self, samples: &mut [f32]) {
        if self.active_bands.is_empty() && (self.preamp_linear - 1.0).abs() < 1e-7 {
            return;
        }
        let ch = self.channels.max(1);
        for (idx, sample) in samples.iter_mut().enumerate() {
            let channel = idx % ch;
            let mut v = *sample * self.preamp_linear;
            for &band in &self.active_bands {
                let state_idx = band * ch + channel;
                v = self.states[state_idx].process(&self.coeffs[band], v);
            }
            *sample = v;
        }
    }

    /// 整条曲线的理论频响（dB），忽略 preamp —— 用于与目标曲线比对。
    pub fn response_db(&self, freq: f32) -> f32 {
        self.coeffs
            .iter()
            .map(|c| c.magnitude_db(freq, self.sample_rate))
            .sum()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flat_curve_is_transparent() {
        let mut eq = Equalizer::new(48000.0, 2);
        eq.apply_curve(&EqCurve::flat());
        let mut buf = vec![0.25f32; 512];
        eq.process_interleaved(&mut buf);
        assert!(
            buf.iter().all(|v| (v - 0.25).abs() < 1e-6),
            "平坦曲线不应改变信号"
        );
    }

    #[test]
    fn boost_is_centered_on_band_frequency() {
        let mut eq = Equalizer::new(48000.0, 2);
        let mut curve = EqCurve::flat();
        curve.gains[17] = 6.0; // 1000 Hz
        eq.apply_curve(&curve);

        let at_1k = eq.response_db(1000.0);
        let at_20k = eq.response_db(20000.0);
        assert!(
            (at_1k - 6.0).abs() < 0.6,
            "1 kHz 处应约 +6 dB，实测 {at_1k}"
        );
        assert!(at_20k.abs() < 0.6, "远处频段不应被拉动，实测 {at_20k}");
    }

    #[test]
    fn headroom_prevents_clipping() {
        let mut curve = EqCurve::flat();
        curve.gains[5] = 9.0;
        let hr = curve.headroom(1.0);
        assert!(
            (hr.preamp + 10.0).abs() < 1e-6,
            "前级应压到 -10 dB，实测 {}",
            hr.preamp
        );
    }

    #[test]
    fn all_bands_sum_to_target_curve() {
        // 每段都给 +3 dB，理论频响在中心频率处应累加
        let mut eq = Equalizer::new(48000.0, 1);
        let mut curve = EqCurve::flat();
        for g in curve.gains.iter_mut() {
            *g = 3.0;
        }
        eq.apply_curve(&curve);
        let at_1k = eq.response_db(1000.0);
        assert!(at_1k > 3.0, "多段叠加后 1 kHz 应高于单段增益，实测 {at_1k}");
    }
}
