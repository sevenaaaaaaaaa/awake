//! 频谱分析：32 段实时频谱与曲目频谱画像（对应 Swift 的 SpectrumAnalyzer /
//! TrackSpectrumAnalyzer）。

use rustfft::{num_complex::Complex, FftPlanner};

/// 32 段频谱（对数分布），覆盖 20 Hz – 20 kHz。
#[derive(Debug, Clone)]
pub struct Spectrum {
    pub bands: [f32; 32],
}

impl Default for Spectrum {
    fn default() -> Self {
        Self { bands: [0.0; 32] }
    }
}

pub struct SpectrumAnalyzer {
    fft_size: usize,
    window: Vec<f32>,
    band_ranges: Vec<(usize, usize)>,
    planner_buffer: Vec<Complex<f32>>,
    fft: std::sync::Arc<dyn rustfft::Fft<f32>>,
}

impl SpectrumAnalyzer {
    pub fn new(fft_size: usize, sample_rate: f32) -> Self {
        let mut planner = FftPlanner::<f32>::new();
        let fft = planner.plan_fft_forward(fft_size);

        // Hann 窗，压低泄漏
        let window = (0..fft_size)
            .map(|i| {
                let x = 2.0 * std::f32::consts::PI * i as f32
                    / (fft_size.saturating_sub(1)).max(1) as f32;
                0.5 - 0.5 * x.cos()
            })
            .collect::<Vec<_>>();

        // 32 段对数频率划分
        let bin_hz = sample_rate / fft_size as f32;
        let f_min = 20.0f32;
        let f_max = (sample_rate * 0.5).min(20_000.0);
        let mut band_ranges = Vec::with_capacity(32);
        for band in 0..32 {
            let lo = f_min * (f_max / f_min).powf(band as f32 / 32.0);
            let hi = f_min * (f_max / f_min).powf((band + 1) as f32 / 32.0);
            let lo_bin = ((lo / bin_hz).floor() as usize).max(1);
            let hi_bin = ((hi / bin_hz).ceil() as usize).min(fft_size / 2);
            band_ranges.push((lo_bin, hi_bin.max(lo_bin + 1)));
        }

        Self {
            fft_size,
            window,
            band_ranges,
            planner_buffer: vec![Complex::new(0.0, 0.0); fft_size],
            fft,
        }
    }

    /// 输入单声道切片（长度任意，内部按 fft_size 截断/补零），输出 32 段 dB。
    pub fn analyze(&mut self, mono: &[f32]) -> Spectrum {
        self.planner_buffer.fill(Complex::new(0.0, 0.0));
        let n = mono.len().min(self.fft_size);
        for i in 0..n {
            self.planner_buffer[i] = Complex::new(mono[i] * self.window[i], 0.0);
        }

        self.fft.process(&mut self.planner_buffer);

        let norm = 2.0 / self.fft_size as f32;
        let mut bands = [0.0f32; 32];
        for (band, (lo, hi)) in self.band_ranges.iter().enumerate() {
            let mut peak = 0.0f32;
            for bin in *lo..*hi {
                let m = self.planner_buffer[bin].norm() * norm;
                if m > peak {
                    peak = m;
                }
            }
            bands[band] = if peak <= 1e-9 {
                -90.0
            } else {
                (20.0 * peak.log10()).clamp(-90.0, 6.0)
            };
        }
        Spectrum { bands }
    }

    /// 整首歌的频谱画像：分块求平均，用于 AutoEQ 匹配。
    pub fn profile(&mut self, mono: &[f32], sample_rate: f32) -> Spectrum {
        let _ = sample_rate;
        let hop = self.fft_size;
        if mono.len() < hop {
            return self.analyze(mono);
        }
        let mut acc = [0.0f32; 32];
        let mut count = 0usize;
        let step = hop / 2;
        let mut start = 0;
        while start + hop <= mono.len() {
            let s = self.analyze(&mono[start..start + hop]);
            for i in 0..32 {
                acc[i] += s.bands[i];
            }
            count += 1;
            start += step;
        }
        if count == 0 {
            return Spectrum::default();
        }
        let mut out = [0.0f32; 32];
        for i in 0..32 {
            out[i] = acc[i] / count as f32;
        }
        Spectrum { bands: out }
    }
}

/// 把交错采样降成单声道，供分析使用。
pub fn to_mono(interleaved: &[f32], channels: usize) -> Vec<f32> {
    if channels <= 1 {
        return interleaved.to_vec();
    }
    interleaved
        .chunks(channels)
        .map(|frame| frame.iter().sum::<f32>() / channels as f32)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_1khz_tone_in_correct_band() {
        let sr = 48_000.0;
        let fft = 4096usize;
        let mut analyzer = SpectrumAnalyzer::new(fft, sr);
        let mono: Vec<f32> = (0..fft)
            .map(|i| (2.0 * std::f32::consts::PI * 1000.0 * i as f32 / sr).sin() * 0.8)
            .collect();

        let spec = analyzer.analyze(&mono);
        let (peak_band, _) = spec
            .bands
            .iter()
            .enumerate()
            .max_by(|a, b| a.1.partial_cmp(b.1).unwrap())
            .unwrap();

        // 1 kHz 在 20 Hz–20 kHz 的对数刻度上 = log(50)/log(1000) ≈ 0.566，即第 18 段
        assert!(
            (17..=19).contains(&peak_band),
            "1 kHz 应落在 19-25 段，实测第 {peak_band} 段，全部: {:?}",
            spec.bands
        );
    }

    #[test]
    fn silence_is_floor() {
        let mut analyzer = SpectrumAnalyzer::new(2048, 48_000.0);
        let spec = analyzer.analyze(&vec![0.0f32; 2048]);
        assert!(spec.bands.iter().all(|b| *b <= -89.0), "静音应贴地板");
    }
}
