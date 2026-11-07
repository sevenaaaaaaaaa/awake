//! 重采样：设备不支持曲目采样率时的兜底，保证时长不变、音高不变。
//!
//! 策略与 Swift 版一致：优先让设备按曲目原生采样率打开（独占/hog 模式），
//! 设备确实不支持时才做高质量重采样。

use anyhow::{anyhow, Result};
use rubato::{
    Resampler, SincInterpolationParameters, SincInterpolationType, WindowFunction,
};

/// 交错 f32 → 分声道 planars。
fn deinterleave(interleaved: &[f32], channels: usize) -> Vec<Vec<f32>> {
    let frames = interleaved.len() / channels.max(1);
    let mut out = vec![Vec::with_capacity(frames); channels];
    for (i, s) in interleaved.iter().enumerate() {
        out[i % channels].push(*s);
    }
    out
}

fn interleave(planars: &[Vec<f32>], channels: usize, out_frames: usize) -> Vec<f32> {
    let mut out = Vec::with_capacity(out_frames * channels);
    for f in 0..out_frames {
        for ch in 0..channels {
            let v = planars
                .get(ch)
                .and_then(|p| p.get(f))
                .copied()
                .unwrap_or(0.0);
            out.push(v);
        }
    }
    out
}

/// 高质量 sinc 重采样。返回交错采样，帧数按比例变化。
pub fn resample_interleaved(
    samples: &[f32],
    channels: usize,
    src_rate: u32,
    dst_rate: u32,
) -> Result<Vec<f32>> {
    if src_rate == dst_rate {
        return Ok(samples.to_vec());
    }
    if channels == 0 {
        return Err(anyhow!("声道数为 0，无法重采样"));
    }

    let ratio = dst_rate as f64 / src_rate as f64;
    let params = SincInterpolationParameters {
        sinc_len: 256,
        f_cutoff: 0.95,
        interpolation: SincInterpolationType::Linear,
        oversampling_factor: 256,
        window: WindowFunction::BlackmanHarris2,
    };

    let chunk = 4096usize;
    let mut resampler = rubato::SincFixedIn::<f32>::new(ratio, 2.0, params, chunk, channels)
        .map_err(|e| anyhow!("重采样器初始化失败: {e}"))?;

    let planars = deinterleave(samples, channels);
    let total_in = planars[0].len();
    let mut output: Vec<Vec<f32>> = vec![Vec::with_capacity((total_in as f64 * ratio) as usize + chunk); channels];

    // 分块送进去，尾部补零确保最后一块也被输出
    let mut pos = 0usize;
    while pos < total_in {
        let end = (pos + chunk).min(total_in);
        let mut block: Vec<Vec<f32>> = Vec::with_capacity(channels);
        for ch in 0..channels {
            let mut v = planars[ch][pos..end].to_vec();
            if v.len() < chunk {
                v.resize(chunk, 0.0);
            }
            block.push(v);
        }
        let out = resampler
            .process(&block, None)
            .map_err(|e| anyhow!("重采样处理失败: {e}"))?;
        for (ch, data) in out.iter().enumerate() {
            output[ch].extend_from_slice(data);
        }
        pos = end;
    }

    let produced = output[0].len();
    let expected = (total_in as f64 * ratio).round() as usize;
    let frames = produced.min(expected.max(1));
    Ok(interleave(&output, channels, frames))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f32::consts::PI;

    fn sine(freq: f32, rate: u32, secs: f32) -> Vec<f32> {
        let n = (rate as f32 * secs) as usize;
        (0..n)
            .map(|i| (2.0 * PI * freq * i as f32 / rate as f32).sin() * 0.5)
            .collect()
    }

    #[test]
    fn halves_frame_count_when_downsampling() {
        let src = sine(1000.0, 96_000, 0.5); // 0.5 秒
        let out = resample_interleaved(&src, 1, 96_000, 48_000).expect("应能重采样");
        let expected = 24_000usize;
        assert!(
            (out.len() as i64 - expected as i64).abs() < 200,
            "48k 下应约 {expected} 帧，实测 {}",
            out.len()
        );
    }

    #[test]
    fn preserves_frequency_not_just_length() {
        // 重采样后 1 kHz 仍应是 1 kHz：过零点计数验证
        let src = sine(1000.0, 96_000, 0.5);
        let out = resample_interleaved(&src, 1, 96_000, 48_000).expect("应能重采样");

        let crossings = out
            .windows(2)
            .filter(|w| w[0] <= 0.0 && w[1] > 0.0)
            .count();
        // 0.5 秒 1 kHz = 500 个周期
        assert!(
            (crossings as i64 - 500).abs() <= 5,
            "应约 500 次正向过零，实测 {crossings} —— 若明显偏少说明音高被改变了"
        );
    }

    #[test]
    fn stereo_channels_stay_separate() {
        let mut src = Vec::new();
        for i in 0..9600 {
            src.push(0.5); // 左
            src.push(-0.5); // 右
        }
        let out = resample_interleaved(&src, 2, 96_000, 48_000).expect("应能重采样");
        let mid = out.len() / 2;
        let l = out[mid - 2];
        let r = out[mid - 1];
        assert!(l > 0.4 && r < -0.4, "左右声道不应串扰，实测 L={l} R={r}");
    }
}
