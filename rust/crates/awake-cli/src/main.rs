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
        "radio" => {
            let sub = args.get(1).map(String::as_str).unwrap_or("probe");
            let target = args.get(2).context("缺少电台地址或文件路径")?;
            match sub {
                "probe" => {
                    let secs: f64 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(4.0);
                    let flags = parse_flags(&args[4..])?;
                    cmd_radio_probe(target, secs, &flags)
                }
                "verdict" => {
                    let flags = parse_flags(&args[3..])?;
                    cmd_radio_verdict(target, &flags)
                }
                other => bail!("radio 只支持 probe / verdict，收到 {other}"),
            }
        }
        "mbl" => {
            let sub = args.get(1).map(String::as_str).unwrap_or("inspect");
            let target = args.get(2).context("缺少 .mbl 路径")?;
            let flags = parse_flags(&args[3..])?;
            match sub {
                "inspect" => cmd_mbl_inspect(Path::new(target), &flags),
                "apply" => cmd_mbl_apply(Path::new(target), &flags),
                "tags" => cmd_mbl_tags(Path::new(target), &flags),
                other => bail!("mbl 只支持 inspect / apply / tags，收到 {other}"),
            }
        }
        "classical-check" => {
            let target = args.get(1).context("缺少 library.json 路径（或数据目录）")?;
            cmd_classical_check(Path::new(target))
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
    println!("  radio probe <地址|文件> [秒数] [--ext mp3] [--ffmpeg] [--cache 目录] [--uuid 台站id]");
    println!("                           真实解码一段直播流，报编码/采样率/电平；有 --cache 就记进台站缓存");
    println!("  radio verdict <地址> [--cache 目录] [--uuid 台站id]");
    println!("                           只查缓存：这个台探过没有、结论是什么");
    println!("  mbl inspect <.mbl> [--root WINDOWS根] [--mount 本地挂载点] [--map \"F:\\Music=/Volumes/F\" ...]");
    println!("                           只读解析 MusicBee 曲库（不写回）；跨盘就多给几个 --map");
    println!("  mbl tags <.mbl> [--tag 65=TrackTitle ...]");
    println!("                           列出这份库真实出现过的 tag 码 + 样例值，用来验证/纠正码表");
    println!("  classical-check <library.json|数据目录>");
    println!("                           在真实曲库上量古典解析命中率，并列出解析不到的样例");
    println!("  mbl apply <.mbl> --library <数据目录> --map \"F:\\Music=/Volumes/F\" [--map ...]");
    println!("                           [--source 来源ID] [--dry-run] [--force]");
    println!("                           把播放次数/上次播放/入库时间导入 Awake 曲库（只增不减）");
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

/// MusicBee 曲库只读体检：条数、首末路径、播放次数、可选的路径映射结果。
///
/// 这个命令存在的意义：D1/D2 的验收要一条能对真实文件重跑的命令，而不是"我读过了"。
/// 解析 `--key value` 与布尔开关（dry-run / force / yes）。
fn parse_flags(args: &[String]) -> Result<std::collections::HashMap<String, String>> {
    let mut map = std::collections::HashMap::new();
    let mut i = 0;
    while i < args.len() {
        let raw = &args[i];
        let key = raw
            .strip_prefix("--")
            .with_context(|| format!("未知参数: {raw}"))?
            .to_string();
        if matches!(key.as_str(), "dry-run" | "force" | "yes" | "ffmpeg") {
            map.insert(key, "1".to_string());
            i += 1;
            continue;
        }
        let value = args.get(i + 1).with_context(|| format!("--{key} 需要值"))?.clone();
        // --map / --tag 可以重复给：跨盘要多个挂载点，覆盖码表要多个码。
        // 用换行拼起来，读取时按行拆——这样不会与路径里的空格、逗号打架。
        if matches!(key.as_str(), "map" | "tag") {
            map.entry(key)
                .and_modify(|slot: &mut String| {
                    slot.push('\n');
                    slot.push_str(&value);
                })
                .or_insert(value);
        } else {
            map.insert(key, value);
        }
        i += 2;
    }
    Ok(map)
}

fn state_value(text: &str, key: &str) -> Option<String> {
    text.lines().find_map(|line| {
        let (k, v) = line.split_once('=')?;
        (k.trim() == key).then(|| v.trim().to_string())
    })
}

/// 把 MusicBee 的注解导入 Awake 曲库：只读 .mbl，只增不减，写前备份。
///
/// 这是 D5–D6 的可执行形态：没有界面，但语义与将来的向导一致——
/// 先算（headline 里全是数字）、再确认（--dry-run）、最后落库（写前备份 + 状态文件）。
fn cmd_mbl_apply(mbl: &Path, flags: &std::collections::HashMap<String, String>) -> Result<()> {
    use awake_core::musicbee;
    use awake_core::musicbee_import::{apply, plan_multi, Snapshot, SourceRoot};
    use awake_core::Library;

    let library_arg = flags
        .get("library")
        .context("缺少 --library（数据目录或 library.json 路径）")?;
    let library_path = {
        let p = Path::new(library_arg);
        if p.extension().map(|e| e == "json").unwrap_or(false) {
            p.to_path_buf()
        } else {
            p.join("library.json")
        }
    };
    let data_dir = library_path
        .parent()
        .context("--library 路径没有父目录")?
        .to_path_buf();
    // 跨盘：--map 可以给多次；旧的 --root/--mount 仍认，等价于一对。
    let mut pairs = parse_mappings(flags)?;
    if pairs.is_empty() {
        match (flags.get("root"), flags.get("mount")) {
            (Some(win), Some(posix)) => pairs.push((win.clone(), posix.clone())),
            _ => bail!(
                "缺少映射。用 --map \"F:\\\\Music=/Volumes/Music\"（跨盘就重复给多个）；\
                 旧的 --root + --mount 也认。"
            ),
        }
    }
    let maps_line = pairs
        .iter()
        .map(|(win, posix)| format!("{win}={posix}"))
        .collect::<Vec<_>>()
        .join("|");
    let dry_run = flags.contains_key("dry-run");

    let bytes = std::fs::read(mbl).with_context(|| format!("读不到 {}", mbl.display()))?;
    let meta = std::fs::metadata(mbl).with_context(|| format!("读不到 {}", mbl.display()))?;
    let modified_ms = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);
    let snapshot = Snapshot { len: meta.len(), modified_ms };

    let sidecar = data_dir.join("musicbee-import.state");
    if !flags.contains_key("force") {
        let prev = std::fs::read_to_string(&sidecar).unwrap_or_default();
        let same = state_value(&prev, "len") == Some(snapshot.len.to_string())
            && state_value(&prev, "modified_ms") == Some(snapshot.modified_ms.to_string())
            && state_value(&prev, "maps") == Some(maps_line.clone());
        if same {
            println!(
                "未变化：{} 字节 / 修改时间 {} 与上次导入一致，跳过（--force 可强制重跑）。",
                snapshot.len, snapshot.modified_ms
            );
            return Ok(());
        }
    }

    let lib = musicbee::parse(&bytes).context("解析 .mbl 失败；曲库与注解都没有改动")?;
    let mut store = Library::open(&library_path);

    let mut roots: Vec<(String, String)> = store
        .snapshot
        .sources
        .iter()
        .filter(|s| s.enabled && s.url.starts_with('/'))
        .map(|s| (s.id.clone(), s.url.clone()))
        .collect();
    if let Some(only) = flags.get("source") {
        roots.retain(|(id, _)| id == only);
    }
    if roots.is_empty() {
        bail!("曲库里没有可用的本地来源（url 必须是绝对路径）。先把音乐文件夹加成本地来源，或用 --source 指定。");
    }
    let refs: Vec<SourceRoot> = roots
        .iter()
        .map(|(id, root)| SourceRoot { source_id: id.as_str(), root: root.as_str() })
        .collect();

    let mounts: Vec<awake_core::musicbee::Mount<'_>> =
        pairs.iter().map(|(win, posix)| awake_core::musicbee::Mount::new(win, posix)).collect();
    let plan = plan_multi(&lib, &store.snapshot.tracks, &refs, &mounts);
    println!("{}", plan.headline());
    if plan.case_insensitive > 0 {
        println!("（其中 {} 条靠忽略大小写匹配上）", plan.case_insensitive);
    }
    for item in plan.matched.iter().filter(|m| m.changed).take(5) {
        println!("  会改: {} → {}", item.track_id, item.posix_path);
    }
    for path in plan.unmatched.iter().take(5) {
        println!("  对不上: {path}");
    }

    if dry_run {
        println!("dry-run：没有写任何文件。");
        return Ok(());
    }

    let report = apply(&mut store.snapshot.tracks, &plan);
    if report.updated > 0 {
        let dir = data_dir
            .join("backups")
            .join(format!("musicbee-{}", awake_core::models::now_ms()));
        std::fs::create_dir_all(&dir).ok();
        std::fs::copy(&library_path, dir.join("library.json")).ok();
        store.save()?;
        println!(
            "已写入曲库: {} 首（播放次数 {} · 上次播放 {} · 入库时间 {}）",
            report.updated, report.play_count_raised, report.last_played_moved, report.added_at_filled
        );
        println!("写入前备份: {}", dir.display());
    } else {
        println!("没有需要改的曲目（曲库未写入）。");
    }

    // 旧字段（win_root/mount）保留成第一个映射：老版本读这份 state 也不会当成"变了"。
    let (first_win, first_mount) = pairs.first().cloned().unwrap_or_default();
    let state = format!(
        "len={}\nmodified_ms={}\nwin_root={}\nmount={}\nmaps={}\nimported_at={}\nupdated={}\n",
        snapshot.len,
        snapshot.modified_ms,
        first_win,
        first_mount,
        maps_line,
        awake_core::models::now_ms(),
        report.updated
    );
    std::fs::write(&sidecar, state).with_context(|| format!("写不了 {}", sidecar.display()))?;
    Ok(())
}

/// 让 ChildStdout 满足 MediaSource 要求的 Sync：加一层互斥。
struct Shared<R>(std::sync::Mutex<R>);

impl<R> Shared<R> {
    fn new(inner: R) -> Self {
        Self(std::sync::Mutex::new(inner))
    }
}

impl<R: std::io::Read> std::io::Read for Shared<R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let mut guard = self
            .0
            .lock()
            .map_err(|_| std::io::Error::new(std::io::ErrorKind::Other, "读取锁被污染"))?;
        guard.read(buf)
    }
}

fn guess_ext(target: &str) -> Option<&'static str> {
    let path = target.split('?').next().unwrap_or(target).to_lowercase();
    for ext in ["mp3", "aac", "ogg", "opus", "flac", "wav"] {
        if path.ends_with(&format!(".{ext}")) {
            return Some(match ext {
                "mp3" => "mp3",
                "aac" => "aac",
                "ogg" => "ogg",
                "opus" => "opus",
                "flac" => "flac",
                _ => "wav",
            });
        }
    }
    None
}

/// 真实解码一段流：地址走 curl 管道，文件直接读。数字全部来自解码结果。
fn cache_path(arg: &str) -> PathBuf {
    let path = Path::new(arg);
    if path.extension().map(|e| e == "json").unwrap_or(false) {
        path.to_path_buf()
    } else {
        path.join("radio-cache.json")
    }
}

fn load_cache(path: &Path) -> awake_core::radio::ProbeCache {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|text| serde_json::from_str::<awake_core::radio::ProbeCache>(&text).ok())
        .unwrap_or_default()
}

fn save_cache(path: &Path, cache: &awake_core::radio::ProbeCache) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).ok();
    }
    let text = serde_json::to_string_pretty(cache)?;
    std::fs::write(path, text).with_context(|| format!("写不了 {}", path.display()))?;
    Ok(())
}

/// 真实解码一段流：地址走 curl 管道，文件直接读。数字全部来自解码结果。
/// 给了 `--cache` 就把结论写进台站缓存——这就是"播放前探测一次"的那一次。
fn cmd_radio_probe(target: &str, secs: f64, flags: &std::collections::HashMap<String, String>) -> Result<()> {
    use awake_core::radio::ProbeRecord;
    use awake_core::stream::{decode_summary, StreamSummary};

    let hint = flags.get("ext").map(String::as_str).or_else(|| guess_ext(target));
    println!("来源: {target}");
    if let Some(hint) = hint {
        println!("提示: .{hint}（只帮 probe 少猜，不决定结果）");
    }

    let direct: Result<StreamSummary> = if target.starts_with("http://") || target.starts_with("https://") {
        let mut child = std::process::Command::new("curl")
            .args([
                "-sS",
                "--max-time",
                &format!("{:.0}", secs.max(1.0) + 8.0),
                "-A",
                &format!("awake/{}", env!("CARGO_PKG_VERSION")),
                target,
            ])
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
            .context("起不了 curl")?;
        let stdout = child.stdout.take().context("curl 没有输出管道")?;
        let decoded = decode_summary(Shared::new(stdout), hint, secs);
        child.kill().ok();
        child.wait().ok();
        decoded
    } else {
        let file = std::fs::File::open(target).with_context(|| format!("读不到 {target}"))?;
        decode_summary(file, hint, secs)
    };

    // 直接解不了时的两条路：给了 --ffmpeg 就兜底；没给就说清怎么打开。
    let (summary, path_label) = match direct {
        Ok(summary) => (summary, "symphonia"),
        Err(error) => {
            if flags.contains_key("ffmpeg") {
                // 标签的优先顺序：手填 > 扩展名 > 问 ffprobe > unknown。
                // 不猜：拿不到就写 unknown，缓存里也不会被当成真编码。
                let label = flags
                    .get("codec")
                    .map(String::as_str)
                    .map(str::to_string)
                    .or_else(|| guess_ext(target).map(str::to_string))
                    .or_else(|| awake_core::stream::identify_codec(target))
                    .unwrap_or_else(|| "unknown".to_string());
                println!("直接解码失败（{error}），改用 ffmpeg 兜底…");
                (
                    awake_core::stream::decode_via_ffmpeg(target, secs, &label)?,
                    "ffmpeg",
                )
            } else {
                let present = awake_core::stream::ffmpeg_path().is_some();
                let advice = if present {
                    "直接解码失败。这个编码不在 symphonia 覆盖范围内——加 --ffmpeg 用 ffmpeg 兜底（本机已找到 ffmpeg）。"
                } else {
                    "直接解码失败。加 --ffmpeg 可以兜底，但本机还没装 ffmpeg（brew install ffmpeg）。"
                };
                return Err(error).with_context(|| advice.to_string());
            }
        }
    };

    println!("解码路径: {path_label}");
    println!(
        "编码: {} · {:.1} kHz · {} 声道",
        summary.format.codec,
        summary.format.sample_rate as f64 / 1000.0,
        summary.format.channels
    );
    println!(
        "解出: {:.2} 秒（{} 帧 · 坏帧 {}）",
        summary.decoded_secs, summary.frames, summary.bad_packets
    );
    println!("电平: RMS {:.1} dBFS · 峰值 {:.3}", summary.rms_db, summary.peak);

    if let Some(dir) = flags.get("cache") {
        let path = cache_path(dir);
        let mut cache = load_cache(&path);
        let key = awake_core::radio::key_for(
            flags.get("uuid").map(String::as_str).unwrap_or(""),
            target,
        );
        let record = ProbeRecord::from_probe(
            &summary.format.codec,
            summary.format.sample_rate,
            summary.format.channels,
            awake_core::models::now_ms(),
        );
        cache.record(key.clone(), record.clone());
        save_cache(&path, &cache)?;
        println!(
            "缓存: {key} → {}（playable={}）已写入 {}",
            record.codec,
            record.playable,
            path.display()
        );
    }
    Ok(())
}


/// 只查缓存：这个台探过没有。没有就是"需要先探一次"，不拿台站声明冒充结论。
fn cmd_radio_verdict(target: &str, flags: &std::collections::HashMap<String, String>) -> Result<()> {
    let dir = flags.get("cache").context("缺少 --cache（数据目录或缓存文件路径）")?;
    let path = cache_path(dir);
    let cache = load_cache(&path);
    let key = awake_core::radio::key_for(
        flags.get("uuid").map(String::as_str).unwrap_or(""),
        target,
    );
    println!("来源: {target}");
    println!("缓存文件: {}", path.display());
    match cache.stations.get(&key) {
        Some(record) => {
            println!(
                "结论: {} · {:.1} kHz · {} 声道 · 直接可放={} · 探测于 {}",
                record.codec,
                record.sample_rate as f64 / 1000.0,
                record.channels,
                record.playable,
                record.probed_at_ms
            );
            println!("备注: {}", record.note);

            // 开关状态从命令行取（桌面版将来从设置里取），这里只是同一个判定的两个入口。
            let enabled = flags.contains_key("ffmpeg");
            let present = awake_core::stream::ffmpeg_path().is_some();
            match awake_core::radio::plan(&record.codec, enabled, present) {
                awake_core::radio::PlaybackPlan::Direct => println!("计划: 直接播放"),
                awake_core::radio::PlaybackPlan::ViaFfmpeg => println!("计划: 走 ffmpeg 兜底"),
                awake_core::radio::PlaybackPlan::Blocked { reason, can_enable_ffmpeg } => {
                    println!("计划: 放不了 —— {reason}");
                    if can_enable_ffmpeg {
                        println!("提示: 加 --ffmpeg（桌面版在设置里打开「用 ffmpeg 兜底」）");
                    }
                }
            }
        }
        None => {
            println!("未探测：缓存里没有这条（键 {key}）。播放前要先 probe 一次。");
        }
    }
    Ok(())
}


/// 把重复给出的 `--map "Windows根=本机挂载点"` 拆成对。
///
/// Windows 路径里不会出现 `=`，所以按第一个 `=` 切是安全的；
/// 用 `=` 而不是 `:`，因为 `F:\Music` 自己就带冒号。
fn parse_mappings(flags: &std::collections::HashMap<String, String>) -> Result<Vec<(String, String)>> {
    let mut out: Vec<(String, String)> = Vec::new();
    if let Some(list) = flags.get("map") {
        for line in list.lines() {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            let (win, posix) = line.split_once('=').with_context(|| {
                format!("--map 要写成 \"Windows根=本机挂载点\"，收到 {line}")
            })?;
            if win.trim().is_empty() || posix.trim().is_empty() {
                bail!("--map 两边都不能空，收到 {line}");
            }
            out.push((win.trim().to_string(), posix.trim().to_string()));
        }
    }
    Ok(out)
}

/// 把重复给出的 `--tag 65=TrackTitle` 拆成覆盖对。码必须是 0..=255 的整数。
fn parse_tag_overrides(
    flags: &std::collections::HashMap<String, String>,
) -> Result<Vec<(u8, String)>> {
    let mut out: Vec<(u8, String)> = Vec::new();
    if let Some(list) = flags.get("tag") {
        for line in list.lines() {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            let (code, name) = line
                .split_once('=')
                .with_context(|| format!("--tag 要写成 \"码=名字\"，收到 {line}"))?;
            let code: u8 = code
                .trim()
                .parse()
                .with_context(|| format!("tag 码必须是 0..=255，收到 {}", code.trim()))?;
            if name.trim().is_empty() {
                bail!("--tag {code}= 少了名字");
            }
            out.push((code, name.trim().to_string()));
        }
    }
    Ok(out)
}

/// 这份库真实用了哪些 tag 码：一行一个，带样例值。
///
/// 这是码表唯一的验证手段——不推断语义，只把 `码 / 名字 / 条数 / 样例` 摆出来，
/// 让人一眼判断"样例值说得通名字吗"。对不上就改 `musicbee_tags::TAG_CODES`。
/// 在**自己的** library.json 上量古典解析命中率。
///
/// 这是唯一能给出"真实命中率"的命令：语料测试用的是重建的写法，
/// 只有跑在你自己的曲库上，数字才是你的库的数字。
fn cmd_classical_check(path: &Path) -> Result<()> {
    use awake_core::shelf;

    let library_path = if path.extension().map(|ext| ext == "json").unwrap_or(false) {
        path.to_path_buf()
    } else {
        path.join("library.json")
    };
    let library = awake_core::Library::open(&library_path);
    let tracks = &library.snapshot.tracks;
    println!("曲库: {} 首（{}）", tracks.len(), library_path.display());
    if tracks.is_empty() {
        println!("曲库是空的，或者这个路径不是 Awake 的 library.json。");
        return Ok(());
    }

    let groups = shelf::overview(tracks);
    let Some(group) = groups.iter().find(|g| g.key == "classical") else {
        println!("这份曲库没有古典专架。");
        println!("分类层要求至少两个信号同时成立（流派 / 作品号 / 专辑结构），一条都没凑够。");
        println!("这不是解析失败——解析根本没被叫到。先确认流派标签写的是 Classical。");
        return Ok(());
    };

    let total = group.count;
    let in_works: usize = group.works.iter().map(|work| work.movement_count).sum();
    let with_catalogue: usize = group
        .works
        .iter()
        .filter(|work| !work.catalogue.is_empty())
        .map(|work| work.movement_count)
        .sum();

    println!("古典曲目: {total} 首");
    println!(
        "归入作品: {in_works} 首（{:.1}%）· 作品 {} 个",
        percent(in_works, total),
        group.works.len()
    );
    println!(
        "其中带作品号: {with_catalogue} 首（{:.1}%）",
        percent(with_catalogue, total)
    );

    let mut covered = std::collections::HashSet::new();
    for work in &group.works {
        for id in &work.track_ids {
            covered.insert(id.clone());
        }
    }
    let missing: Vec<&awake_core::Track> = group
        .track_ids
        .iter()
        .filter(|id| !covered.contains(*id))
        .filter_map(|id| tracks.iter().find(|track| &track.id == id))
        .take(10)
        .collect();
    if missing.is_empty() {
        println!("每一首古典曲目都归进了作品。");
    } else {
        println!();
        println!("没归入作品的样例（前 {} 条）:", missing.len());
        for track in missing {
            println!(
                "  {:<38} | {:<42} | {}",
                clip(&track.album, 38),
                clip(&track.title, 42),
                clip(&track.artist, 24)
            );
        }
        println!();
        println!("这些就是真实库里解析不到的部分：按上面的写法补正则或词典，不要改调用方。");
    }
    Ok(())
}

fn percent(part: usize, total: usize) -> f64 {
    if total == 0 {
        0.0
    } else {
        100.0 * part as f64 / total as f64
    }
}

/// 按字符截断（不是字节）：中文按字节截会切出半个字。
fn clip(text: &str, width: usize) -> String {
    if text.chars().count() <= width {
        return text.to_string();
    }
    let mut out: String = text.chars().take(width.saturating_sub(1)).collect();
    out.push('…');
    out
}

fn cmd_mbl_tags(path: &Path, flags: &std::collections::HashMap<String, String>) -> Result<()> {
    use awake_core::musicbee;
    use awake_core::musicbee_tags;

    let bytes = std::fs::read(path).with_context(|| format!("读不到 {}", path.display()))?;
    let lib = musicbee::parse(&bytes).context("解析 .mbl 失败")?;
    let overrides = parse_tag_overrides(flags)?;
    let lookup: std::collections::HashMap<u8, &str> =
        overrides.iter().map(|(code, name)| (*code, name.as_str())).collect();

    println!("文件: {}", path.display());
    println!("解析: {} 条（声明 {} 条）", lib.records.len(), lib.declared);

    let roots = musicbee::windows_roots(&lib.records);
    println!();
    println!("跨 {} 个 Windows 根:", roots.len());
    for (root, count) in &roots {
        println!("  {:<40} {:>6} 条", root, count);
    }
    if roots.len() > 1 {
        println!("  → 跨盘库。导入时每个根要一个 --map，例如：");
        for (root, _) in &roots {
            println!("      --map \"{root}=/Volumes/填这里\"");
        }
    }

    let stats = musicbee_tags::census(&lib.records);
    if stats.is_empty() {
        println!();
        println!("这份库一条标签都没有（只有路径与播放次数）。");
        return Ok(());
    }
    println!();
    println!("出现 {} 种 tag 码（码  名字  条数  样例）:", stats.len());
    for stat in &stats {
        println!("{}", stat.line_with(lookup.get(&stat.code).copied()));
    }

    let unknown: Vec<u8> = stats
        .iter()
        .filter(|s| s.name.is_none() && !lookup.contains_key(&s.code))
        .map(|s| s.code)
        .collect();
    let used: usize = stats
        .iter()
        .filter(|s| s.name.is_some() || lookup.contains_key(&s.code))
        .count();
    println!();
    println!(
        "表内 {} 个码；这份库用到 {} 个；剩下 {} 个没出现（不代表表错，只代表这份库没这个标签）。",
        musicbee_tags::TAG_CODES.len(),
        used,
        musicbee_tags::TAG_CODES.len().saturating_sub(used)
    );
    if unknown.is_empty() {
        println!("没有表外的码。");
    } else {
        println!(
            "{} 个表外的码: {unknown:?} —— 真实文件里有、码表还没有的标签。",
            unknown.len()
        );
        println!("确认语义后用 --tag 码=名字 看覆盖效果，再决定要不要加进 TAG_CODES。");
    }
    println!();
    println!("注意：码表来自官方插件 SDK 的 MetaDataType 枚举，未用真实 .mbl 验证过——");
    println!("     上面每一行的样例值就是判据：语义对不上，就是表错了。");
    Ok(())
}

fn cmd_mbl_inspect(path: &Path, flags: &std::collections::HashMap<String, String>) -> Result<()> {
    use awake_core::musicbee;

    let bytes = std::fs::read(path).with_context(|| format!("读不到 {}", path.display()))?;
    let lib = musicbee::parse(&bytes).context("解析 .mbl 失败")?;

    println!("文件: {}", path.display());
    println!("大小: {} 字节", bytes.len());
    println!("版本: {}", lib.version);
    println!("声明: {} 条", lib.declared);
    println!("解析: {} 条", lib.records.len());
    println!("尾部: {} 字节", lib.trailing_bytes);
    if let Some(first) = lib.records.first() {
        println!("首条: {}", first.path);
    }
    if let Some(last) = lib.records.last() {
        println!("末条: {}", last.path);
    }
    let plays: u32 = lib.records.iter().map(|r| r.play_count).sum();
    println!("播放次数合计: {plays}");
    let tagged = lib.records.iter().filter(|r| !r.tags.is_empty()).count();
    println!("带标签: {tagged} 条（码表见 mbl tags，未用真实文件验证）");

    // 跨了几个盘根：一个根就只能给一个挂载点，这是用户最常卡住的地方。
    let roots = musicbee::windows_roots(&lib.records);
    println!("Windows 根: {} 个", roots.len());
    for (root, count) in roots.iter().take(8) {
        println!("  {:<40} {:>6} 条", root, count);
    }
    if roots.len() > 1 {
        println!("  → 跨盘：每个根一个 --map，只给一个会有一半路径落不上。");
    }

    let mut pairs = parse_mappings(flags)?;
    if pairs.is_empty() {
        if let (Some(root), Some(mount)) = (flags.get("root"), flags.get("mount")) {
            pairs.push((root.clone(), mount.clone()));
        }
    }
    if !pairs.is_empty() {
        let mounts: Vec<musicbee::Mount<'_>> =
            pairs.iter().map(|(win, posix)| musicbee::Mount::new(win, posix)).collect();
        let plan = musicbee::plan_multi(&lib.records, &mounts);
        println!("映射: {} 对", mounts.len());
        println!("匹配: {} 条", plan.matched.len());
        println!("未匹配: {} 条", plan.unmatched.len());
        if let Some(first) = plan.matched.first() {
            println!("首条映射: {}", first.posix_path);
        }
        if let Some(first) = plan.unmatched.first() {
            println!("首条未匹配: {first}");
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
