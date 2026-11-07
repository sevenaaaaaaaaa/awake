//! awake-cli —— Rust 核心的可执行验证器。
//!
//! 用法:
//!   awake-cli probe <文件或目录>      读出格式与位深
//!   awake-cli analyze <文件>          打印 32 段频谱画像
//!   awake-cli eq-test <文件>          应用 31 段 EQ，报告峰值与理论频响
//!   awake-cli play <文件> [秒数]      cpal 播放（默认播 5 秒）

use anyhow::{bail, Context, Result};
use awake_core::{analyze, decode, eq, library};
use std::path::{Path, PathBuf};

fn main() -> Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("warn")).init();

    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() {
        print_usage();
        return Ok(());
    }

    match args[0].as_str() {
        "probe" => {
            let target = args.get(1).context("缺少路径")?;
            cmd_probe(Path::new(target))
        }
        "analyze" => {
            let target = args.get(1).context("缺少文件路径")?;
            cmd_analyze(Path::new(target))
        }
        "eq-test" => {
            let target = args.get(1).context("缺少文件路径")?;
            cmd_eq_test(Path::new(target))
        }
        "scan" => {
            let target = args.get(1).context("缺少曲库目录")?;
            cmd_scan(Path::new(target))
        }
        "play" => {
            let target = args.get(1).context("缺少文件路径")?;
            let secs: f32 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(5.0);
            cmd_play(Path::new(target), secs)
        }
        other => {
            bail!("未知命令: {other}");
        }
    }
}

fn print_usage() {
    println!("awake-cli <命令> <参数>");
    println!();
    println!("  probe <文件或目录>      读出格式、采样率、位深");
    println!("  analyze <文件>          打印 32 段频谱画像");
    println!("  scan <目录>             扫描曲库并统计专辑");
    println!("  eq-test <文件>          应用 31 段 EQ 并报告峰值");
    println!("  play <文件> [秒数]      cpal 播放");
}

fn collect_audio_files(path: &Path) -> Result<Vec<PathBuf>> {
    if path.is_file() {
        return Ok(vec![path.to_path_buf()]);
    }
    let mut out = Vec::new();
    let mut stack = vec![path.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(&dir).with_context(|| format!("读不了目录 {}", dir.display()))? {
            let p = entry?.path();
            if p.is_dir() {
                stack.push(p);
            } else if library::is_audio_file(&p) {
                out.push(p);
            }
        }
    }
    out.sort();
    Ok(out)
}

fn cmd_probe(path: &Path) -> Result<()> {
    let files = collect_audio_files(path)?;
    if files.is_empty() {
        bail!("没有找到受支持的音频文件");
    }
    println!("共 {} 个音频文件\n", files.len());
    let mut ok = 0;
    let mut failed = 0;
    for f in &files {
        match decode::probe_format(f) {
            Ok(fmt) => {
                ok += 1;
                let bits = fmt
                    .bits_per_sample
                    .map(|b| format!("{b}-bit"))
                    .unwrap_or_else(|| "位深未知".into());
                let dur = fmt
                    .duration_secs
                    .map(|d| format!("{:.1}s", d))
                    .unwrap_or_else(|| "时长未知".into());
                let kind = if fmt.is_hires() { "Hi-Res" } else { "标准" };
                println!(
                    "{:<40} {:>6} Hz  {}ch  {}  {:<7} {:<8} {}",
                    f.file_name().unwrap_or_default().to_string_lossy(),
                    fmt.sample_rate,
                    fmt.channels,
                    bits,
                    fmt.codec,
                    dur,
                    kind
                );
            }
            Err(e) => {
                failed += 1;
                println!("{:<40} ✗ {}", f.file_name().unwrap_or_default().to_string_lossy(), e);
            }
        }
    }
    println!("\n成功 {ok} / 失败 {failed}");
    Ok(())
}

fn cmd_scan(root: &Path) -> Result<()> {
    use std::collections::HashMap;
    use std::time::Instant;

    let t0 = Instant::now();
    let mut last_print = 0usize;
    let art_dir = std::env::temp_dir().join("awake-artwork");
    let tracks = library::scan_local_source(root, "src-cli", &HashMap::new(), Some(&art_dir), |done, total, title| {
        if done == total || done - last_print >= 3 {
            last_print = done;
            println!("  扫描中 {done}/{total}  {title}");
        }
    })?;
    let elapsed = t0.elapsed();

    let albums = awake_core::group_albums(&tracks);
    println!();
    println!("曲目: {} 首", tracks.len());
    println!("专辑: {} 张", albums.len());
    println!("耗时: {:.0} ms", elapsed.as_millis());
    println!();

    let hires = tracks.iter().filter(|t| t.is_hires()).count();
    let with_art = tracks.iter().filter(|t| t.artwork_path.is_some()).count();
    println!("Hi-Res: {hires} 首 / 有封面: {with_art} 首");
    println!();

    for album in albums.iter().take(5) {
        println!("《{}》 {}", album.title, album.artist);
        println!(
            "   {} 首 · {:.0} 分 · {}",
            album.tracks.len(),
            album.duration() / 60.0,
            if album.is_hires() { "Hi-Res" } else { "标准" }
        );
        for t in album.tracks.iter().take(3) {
            println!(
                "     {:>2}. {:<24} {}",
                t.track_number.unwrap_or(0),
                t.title,
                t.quality_label()
            );
        }
    }
    Ok(())
}

fn cmd_analyze(path: &Path) -> Result<()> {
    let audio = decode::decode_file(path)?;
    let mono = analyze::to_mono(&audio.samples, audio.format.channels);
    let mut analyzer = analyze::SpectrumAnalyzer::new(8192, audio.format.sample_rate as f32);
    let profile = analyzer.profile(&mono, audio.format.sample_rate as f32);

    println!("文件: {}", path.display());
    println!(
        "格式: {} Hz / {} 声道 / {} / 时长 {:.1}s",
        audio.format.sample_rate,
        audio.format.channels,
        audio.format.codec,
        audio.duration_secs()
    );
    println!("峰值: {:.4}", audio.peak());
    println!();
    println!("32 段频谱 (dB):");
    let f_min = 20.0f32;
    let f_max = (audio.format.sample_rate as f32 * 0.5).min(20_000.0);
    for (i, db) in profile.bands.iter().enumerate() {
        let lo = f_min * (f_max / f_min).powf(i as f32 / 32.0);
        let hi = f_min * (f_max / f_min).powf((i + 1) as f32 / 32.0);
        // 动态范围 -90..0 dB 映射到 0..46 格
        let bar_len = (((db + 90.0) / 90.0).clamp(0.0, 1.0) * 46.0) as usize;
        println!(
            "{:>6.0}-{:<6.0}Hz {:>7.1} |{}",
            lo,
            hi,
            db,
            "█".repeat(bar_len)
        );
    }
    Ok(())
}

fn cmd_eq_test(path: &Path) -> Result<()> {
    let mut audio = decode::decode_file(path)?;
    let before_peak = audio.peak();

    // 模拟 AutoEQ：低频提升 4 dB、中频保持、4 kHz 处 +3 dB、高频轻微衰减
    let mut curve = eq::EqCurve::flat();
    for (i, f) in eq::EQ_BAND_FREQUENCIES.iter().enumerate() {
        curve.gains[i] = match *f as u32 {
            0..=120 => 4.0,
            2050..=5000 => 3.0,
            10000..=20000 => -2.0,
            _ => 0.0,
        };
    }
    let curve = curve.headroom(1.0);

    let mut equalizer = eq::Equalizer::new(
        audio.format.sample_rate as f32,
        audio.format.channels,
    );
    equalizer.apply_curve(&curve);

    println!("文件: {}", path.display());
    println!("应用曲线: preamp {:.1} dB, 最大提升 {:.1} dB", curve.preamp, curve.max_gain());
    println!();
    println!("理论频响:");
    for f in [50.0, 100.0, 250.0, 1000.0, 3000.0, 6000.0, 12000.0, 16000.0] {
        println!("  {:>6.0} Hz  {:>6.2} dB", f, equalizer.response_db(f));
    }

    equalizer.process_interleaved(&mut audio.samples);
    let after_peak = audio.peak();

    println!();
    println!("处理前峰值: {:.4}", before_peak);
    println!("处理后峰值: {:.4}", after_peak);
    let clipped = audio.samples.iter().filter(|s| s.abs() >= 0.999).count();
    println!("削波采样数: {} / {}", clipped, audio.samples.len());
    if clipped == 0 {
        println!("结论: headroom 生效，无削波 ✓");
    } else {
        println!("结论: 出现削波，需要更多余量 ✗");
    }
    Ok(())
}

/// 在设备的受支持配置里找与曲目同采样率、同声道数的配置。
/// 找到就直连（无重采样，音质最好）；找不到返回 None，由调用方重采样兜底。
fn find_native_config(
    device: &cpal::Device,
    rate: u32,
    channels: usize,
) -> Option<cpal::SupportedStreamConfig> {
    use cpal::traits::DeviceTrait;
    let configs = device.supported_output_configs().ok()?;
    for range in configs {
        if range.channels() as usize != channels {
            continue;
        }
        if range.min_sample_rate().0 <= rate && rate <= range.max_sample_rate().0 {
            return Some(range.with_sample_rate(cpal::SampleRate(rate)));
        }
    }
    None
}

fn cmd_play(path: &Path, secs: f32) -> Result<()> {
    use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

    let mut audio = decode::decode_file(path)?;
    let src_rate = audio.format.sample_rate;
    let channels = audio.format.channels;

    // 应用一条示例 EQ，证明链路可用
    let mut curve = eq::EqCurve::flat();
    curve.gains[5] = 2.0;
    let curve = curve.headroom(1.0);
    let mut equalizer = eq::Equalizer::new(src_rate as f32, channels);
    equalizer.apply_curve(&curve);
    equalizer.process_interleaved(&mut audio.samples);

    let host = cpal::default_host();
    let device = host.default_output_device().context("没有可用的音频输出设备")?;
    let device_name = device.name().unwrap_or_else(|_| "未知设备".into());

    // 优先让设备按曲目原生采样率打开（等价 Swift 的按曲目切采样率）
    let native = find_native_config(&device, src_rate, channels);
    let config = match &native {
        Some(c) => c.clone(),
        None => device.default_output_config()?,
    };
    let out_rate = config.sample_rate().0;
    let out_channels = config.channels() as usize;

    println!("输出设备: {device_name}");
    match &native {
        Some(_) => println!("采样率: 设备已切到原生 {out_rate} Hz（与文件一致，无重采样）"),
        None => println!("采样率: 设备支持的最高为 {out_rate} Hz，文件 {src_rate} Hz → 启用重采样"),
    }
    println!("声道: {out_channels}");

    // 采样率不一致时重采样，保证时长与音高不变
    let data = if out_rate != src_rate {
        let t0 = std::time::Instant::now();
        let resampled = awake_core::resample_interleaved(
            &audio.samples,
            channels,
            src_rate,
            out_rate,
        )?;
        println!(
            "重采样完成: {} → {} 帧，耗时 {:.0} ms",
            audio.samples.len() / channels.max(1),
            resampled.len() / channels.max(1),
            t0.elapsed().as_millis()
        );
        resampled
    } else {
        audio.samples.clone()
    };
    let total = data.len() / channels.max(1);
    let limit_frames = ((secs * out_rate as f32) as usize).min(total);
    let mut pos = 0usize;

    let stream = device.build_output_stream(
        &config.config(),
        move |output: &mut [f32], _| {
            output.fill(0.0);
            let frames_wanted = output.len() / out_channels;
            for f in 0..frames_wanted {
                if pos >= limit_frames {
                    continue;
                }
                let src_frame = pos;
                pos += 1;
                for c in 0..out_channels {
                    let src_c = c.min(channels - 1);
                    output[f * out_channels + c] = data[src_frame * channels + src_c];
                }
            }
        },
        move |err| eprintln!("音频流错误: {err}"),
        None,
    )?;

    stream.play()?;
    println!("播放 {secs} 秒…");
    std::thread::sleep(std::time::Duration::from_secs_f32(secs.min(30.0)));
    drop(stream);
    println!("播放结束");
    Ok(())
}
