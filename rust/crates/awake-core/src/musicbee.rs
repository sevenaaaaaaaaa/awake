//! MusicBee 曲库文件（`MusicBeeLibrary.mbl`）的**只读**解析。
//!
//! 事实来源（B 级，非官方规范）：两份互不相关的第三方实现
//! - gist `bountifulellie/6e8977065da593e372e45d4c628e7fc7`（PoC 解析器）
//! - gist `cskaryd/51496f5c6edecba360800c855f32668f`（.NET Ticks 修复）
//!
//! 已知边界，写在这里避免以后当成 bug：
//! 1. **不写回**。MusicBee 运行时持有这个文件，任何写都是数据风险。
//! 2. **tag_code → 字段名 不在这个模块里定**。解析只产出 `(code, value)` 原样对；
//!    码表在 `musicbee_tags`（来自官方 SDK 的 `MetaDataType` 枚举，验证状态与反证条件写在那里），
//!    调用方用 `TagMap::musicbee()` 取，或用 `TagMap::with(...)` 注入自己的表。
//! 3. .NET Ticks 的第 8 字节在真实文件里恒为 `0x08`，解析时按此修正；
//!    全零表示"没有这个时间"，返回 None 而不是 1970。
//! 4. 声明的条数与实际解析条数都露出来（`declared` / `records.len()`），
//!    不一致时由上层提示，不静默截断。

use serde::Serialize;
use std::fmt;

/// 解析失败的位置与原因。宁可报错并保留已读条数，也不静默截断。
#[derive(Debug, Clone, PartialEq)]
pub enum MblError {
    BadHeader { raw: i32 },
    Truncated { need: usize },
    UnknownRecord(u8),
    BadStatus(u8),
    VarintTooLong,
    Utf8,
}

impl fmt::Display for MblError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            MblError::BadHeader { raw } => write!(f, "文件头不合法（raw={raw}）"),
            MblError::Truncated { need } => write!(f, "文件在读取 {need} 字节处提前结束"),
            MblError::UnknownRecord(d) => write!(f, "未知记录类型 {d}（合法范围 1..=9）"),
            MblError::BadStatus(s) => write!(f, "状态码 {s} 超出 0..=6"),
            MblError::VarintTooLong => write!(f, "长度前缀超过 5 字节"),
            MblError::Utf8 => write!(f, "字符串不是合法 UTF-8"),
        }
    }
}

impl std::error::Error for MblError {}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct MblArtwork {
    pub kind: u8,
    pub first: String,
    pub store_mode: u8,
    pub second: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct MblCue {
    pub a: u8,
    pub b: u16,
    pub c: i64,
    pub d: u16,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct MblRecord {
    pub designation: u8,
    pub status: u8,
    pub play_count: u32,
    pub skip_count: u32,
    pub last_played_ms: Option<i64>,
    pub added_ms: Option<i64>,
    pub modified_ms: Option<i64>,
    pub path: String,
    pub file_size: i64,
    pub sample_rate: u32,
    pub channel_mode: u8,
    pub bitrate_type: u8,
    pub bitrate_raw: i16,
    pub track_length_raw: i32,
    pub artwork: Vec<MblArtwork>,
    pub tags_type: u8,
    pub tags: Vec<(u8, String)>,
    pub cue: Vec<MblCue>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct MblLibrary {
    pub version: u8,
    pub declared: u32,
    pub records: Vec<MblRecord>,
    pub trailing_bytes: usize,
}

/// 标签码 → 字段名。三种来源语义不同，不要混：
///
/// - `EMPTY`：没有映射表，一律 None（"不猜"的老行为，有测试钉着）；
/// - `musicbee()`：官方 SDK 的 `MetaDataType` 枚举名（`TrackTitle` / `Album` …），
///   来源与**未验证状态**见 `musicbee_tags`；
/// - `with(...)`：调用方自己注入（CLI `--tag`、测试、覆盖个别码）。
#[derive(Debug, Clone, Default)]
pub struct TagMap {
    pairs: Vec<(u8, &'static str)>,
    builtin: bool,
}

impl TagMap {
    pub const EMPTY: TagMap = TagMap { pairs: Vec::new(), builtin: false };

    pub fn with(pairs: &[(u8, &'static str)]) -> Self {
        Self { pairs: pairs.to_vec(), builtin: false }
    }

    /// MusicBee 官方枚举名。**推断，未用真实 `.mbl` 验证**；反证方法见 `musicbee_tags`。
    pub fn musicbee() -> Self {
        Self { pairs: Vec::new(), builtin: true }
    }

    pub fn is_empty(&self) -> bool {
        !self.builtin && self.pairs.is_empty()
    }

    pub fn label(&self, code: u8) -> Option<&'static str> {
        // 显式覆盖优先于内置表：CLI 要能改一个码而不重编。
        if let Some((_, label)) = self.pairs.iter().find(|(c, _)| *c == code) {
            return Some(*label);
        }
        if self.builtin {
            return crate::musicbee_tags::enumerate(code);
        }
        None
    }

    /// 在这张表之上替换/新增个别码。
    pub fn with_overrides(&self, pairs: &[(u8, &'static str)]) -> Self {
        let mut merged = self.pairs.clone();
        merged.extend_from_slice(pairs);
        Self { pairs: merged, builtin: self.builtin }
    }
}

/// 一条记录落到本地路径后的补丁：只带"别人已经整理好的判断"。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct TrackPatch {
    pub posix_path: String,
    pub play_count: u32,
    pub skip_count: u32,
    pub last_played_ms: Option<i64>,
    pub added_ms: Option<i64>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct PathPlan {
    pub matched: Vec<TrackPatch>,
    pub unmatched: Vec<String>,
}

struct Reader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8], MblError> {
        if self.pos + n > self.buf.len() {
            return Err(MblError::Truncated { need: n });
        }
        let slice = &self.buf[self.pos..self.pos + n];
        self.pos += n;
        Ok(slice)
    }

    fn u8(&mut self) -> Result<u8, MblError> {
        Ok(self.take(1)?[0])
    }

    fn u16(&mut self) -> Result<u16, MblError> {
        let b = self.take(2)?;
        Ok(u16::from_le_bytes([b[0], b[1]]))
    }

    fn i16(&mut self) -> Result<i16, MblError> {
        Ok(self.u16()? as i16)
    }

    fn u32(&mut self) -> Result<u32, MblError> {
        let b = self.take(4)?;
        Ok(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }

    fn i32(&mut self) -> Result<i32, MblError> {
        Ok(self.u32()? as i32)
    }

    fn u64(&mut self) -> Result<u64, MblError> {
        let b = self.take(8)?;
        Ok(u64::from_le_bytes([b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]]))
    }

    fn i64(&mut self) -> Result<i64, MblError> {
        Ok(self.u64()? as i64)
    }

    /// .NET BinaryWriter 的 7-bit 变长整数（长度前缀同款）。
    fn leb(&mut self) -> Result<u64, MblError> {
        let mut value: u64 = 0;
        let mut shift = 0;
        for _ in 0..5 {
            let byte = self.u8()?;
            value |= ((byte & 0x7f) as u64) << shift;
            if byte & 0x80 == 0 {
                return Ok(value);
            }
            shift += 7;
        }
        Err(MblError::VarintTooLong)
    }

    fn string(&mut self) -> Result<String, MblError> {
        let len = self.leb()? as usize;
        if len == 0 {
            return Ok(String::new());
        }
        let bytes = self.take(len)?;
        String::from_utf8(bytes.to_vec()).map_err(|_| MblError::Utf8)
    }

    fn remaining(&self) -> usize {
        self.buf.len().saturating_sub(self.pos)
    }
}

/// .NET Ticks（100ns，起点 0001-01-01）→ Unix 毫秒。
fn dotnet_ticks_to_ms(raw: u64) -> Option<i64> {
    if raw == 0 {
        return None;
    }
    // 真实文件里最高字节恒为 0x08；不是就按已知事实修正，低 7 字节才是数值。
    let ticks = if (raw >> 56) as u8 == 0x08 {
        raw
    } else {
        (raw & 0x00FF_FFFF_FFFF_FFFF) | 0x0800_0000_0000_0000
    };
    let ms = (ticks as i128 - 621_355_968_000_000_000i128) / 10_000;
    Some(ms as i64)
}

pub fn parse(bytes: &[u8]) -> Result<MblLibrary, MblError> {
    let mut r = Reader { buf: bytes, pos: 0 };
    let head = r.i32()?;
    let version = (head & 0xFF) as u8;
    if version == 0 {
        return Err(MblError::BadHeader { raw: head });
    }
    let declared = (head >> 8) as u32;

    let mut records = Vec::new();
    loop {
        if r.remaining() == 0 {
            break;
        }
        let designation = r.u8()?;
        match designation {
            1 => break,
            2..=9 => records.push(read_media(&mut r, designation)?),
            other => return Err(MblError::UnknownRecord(other)),
        }
    }

    Ok(MblLibrary { version, declared, records, trailing_bytes: r.remaining() })
}

fn read_media(r: &mut Reader<'_>, designation: u8) -> Result<MblRecord, MblError> {
    let status = r.u8()?;
    if status > 6 {
        return Err(MblError::BadStatus(status));
    }
    let _unknown = r.u8()?;
    let play_count = r.u16()? as u32;
    let last_played_ms = dotnet_ticks_to_ms(r.u64()?);
    let skip_count = r.u16()? as u32;
    let path = r.string()?;
    let file_size = r.i32()? as i64;
    let sample_rate = r.i32()?.max(0) as u32;
    let channel_mode = r.u8()?;
    let bitrate_type = r.u8()?;
    let bitrate_raw = r.i16()?;
    let track_length_raw = r.i32()?;
    let added_ms = dotnet_ticks_to_ms(r.u64()?);
    let modified_ms = dotnet_ticks_to_ms(r.u64()?);

    let mut artwork = Vec::new();
    loop {
        let kind = r.u8()?;
        if kind > 253 {
            break;
        }
        let first = r.string()?;
        let store_mode = r.u8()?;
        let second = r.string()?;
        artwork.push(MblArtwork { kind, first, store_mode, second });
    }

    let tags_type = r.u8()?;
    let mut tags = Vec::new();
    let mut cue = Vec::new();
    loop {
        let code = r.u8()?;
        if code == 0 {
            break;
        }
        if code == 255 {
            let count = r.i16()?.max(0) as usize;
            for _ in 0..count {
                cue.push(MblCue { a: r.u8()?, b: r.u16()?, c: r.i64()?, d: r.u16()? });
            }
            break;
        }
        tags.push((code, r.string()?));
    }

    Ok(MblRecord {
        designation,
        status,
        play_count,
        skip_count,
        last_played_ms,
        added_ms,
        modified_ms,
        path,
        file_size,
        sample_rate,
        channel_mode,
        bitrate_type,
        bitrate_raw,
        track_length_raw,
        artwork,
        tags_type,
        tags,
        cue,
    })
}

/// Windows 绝对路径 → 挂载点下的 POSIX 路径。根不匹配返回 None（由上层显示为未匹配）。
pub fn map_windows_path(path: &str, win_root: &str, posix_root: &str) -> Option<String> {
    fn norm(p: &str) -> String {
        let mut s = p.replace('\\', "/");
        while s.ends_with('/') {
            s.pop();
        }
        s
    }
    let file = norm(path);
    let root = norm(win_root);
    if root.is_empty() || file.len() <= root.len() {
        return None;
    }
    let (head, tail) = file.split_at(root.len());
    if !head.eq_ignore_ascii_case(&root) {
        return None;
    }
    // 段边界判断：F:\Music 不能匹配 F:\Music2
    let tail = tail.strip_prefix('/')?;
    if tail.is_empty() {
        return None;
    }
    let base = norm(posix_root);
    if base.is_empty() {
        return None;
    }
    Some(format!("{base}/{tail}"))
}

/// 一个「Windows 根 → 本机挂载点」的对。
///
/// 一个根不够用：真实曲库常跨盘（`F:\Music` 与 `G:\Archive`），
/// 也常一个盘挂两处（外置盘换过名字）。跨盘就传多个 `Mount`。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Mount<'a> {
    pub win_root: &'a str,
    pub posix_root: &'a str,
}

impl<'a> Mount<'a> {
    pub fn new(win_root: &'a str, posix_root: &'a str) -> Self {
        Self { win_root, posix_root }
    }
}

/// 把一份库落到一组挂载点上。
///
/// 同一条记录被多个 `Mount` 命中时取 **`win_root` 最长**的那个：
/// `F:\Music` 比 `F:\` 更具体，用户加它就是为了让映射落到对的目录。
/// 长度相同就保持传入顺序，先传的先命中——结果因此是可预期的，不靠 HashMap 顺序。
pub fn plan_multi(records: &[MblRecord], mounts: &[Mount<'_>]) -> PathPlan {
    // 最长根优先：更具体的映射必须赢过更宽的映射。
    let mut ordered: Vec<Mount<'_>> = mounts.to_vec();
    ordered.sort_by_key(|m| std::cmp::Reverse(m.win_root.len()));

    let mut plan = PathPlan::default();
    for record in records {
        let hit = ordered
            .iter()
            .find_map(|m| map_windows_path(&record.path, m.win_root, m.posix_root));
        match hit {
            Some(posix) => plan.matched.push(TrackPatch {
                posix_path: posix,
                play_count: record.play_count,
                skip_count: record.skip_count,
                last_played_ms: record.last_played_ms,
                added_ms: record.added_ms,
            }),
            None => plan.unmatched.push(record.path.clone()),
        }
    }
    plan
}

/// 单盘便捷入口，等价于 `plan_multi(records, &[Mount::new(win_root, posix_root)])`。
pub fn plan(records: &[MblRecord], win_root: &str, posix_root: &str) -> PathPlan {
    plan_multi(records, &[Mount::new(win_root, posix_root)])
}

/// 从一条 Windows 路径猜它所属的根（只作预填，用户可改）：
/// `F:\Music\Artist\01.flac` → `F:\Music`；`F:\01.flac` → `F:`；
/// `\\NAS\music\x.flac` → `\\NAS\music`。
pub fn guess_root(path: &str) -> String {
    if path.starts_with(r"\\") {
        let parts: Vec<&str> = path.trim_start_matches('\\').split('\\').collect();
        if parts.len() >= 2 && !parts[1].is_empty() {
            return format!("\\\\{}\\{}", parts[0], parts[1]);
        }
        return path.to_string();
    }
    let parts: Vec<&str> = path.split('\\').collect();
    if parts.len() >= 3 && !parts[0].is_empty() && !parts[1].is_empty() {
        format!("{}\\{}", parts[0], parts[1])
    } else if !parts.is_empty() && !parts[0].is_empty() {
        parts[0].to_string()
    } else {
        String::new()
    }
}

/// 这份库跨了几个 Windows 根，各自多少条，按条数降序。
///
/// 界面靠它决定"要几个挂载点输入"：一个盘一个，而不是让用户在一个框里猜。
/// 大小写不敏感地合并（`F:` 与 `f:` 是同一个盘）。
pub fn windows_roots(records: &[MblRecord]) -> Vec<(String, usize)> {
    let mut out: Vec<(String, usize)> = Vec::new();
    for record in records {
        let root = guess_root(&record.path);
        if root.is_empty() {
            continue;
        }
        match out.iter_mut().find(|(seen, _)| seen.eq_ignore_ascii_case(&root)) {
            Some((_, count)) => *count += 1,
            None => out.push((root, 1)),
        }
    }
    out.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    out
}

/// 播放次数只允许"取较大值"：不把用户刚在 Awake 里听的记录冲回旧数字。
pub fn merge_play_count(existing: u32, incoming: u32) -> u32 {
    existing.max(incoming)
}

pub fn tag_value<'a>(record: &'a MblRecord, map: &TagMap, field: &str) -> Option<&'a str> {
    record
        .tags
        .iter()
        .find(|(code, _)| map.label(*code) == Some(field))
        .map(|(_, value)| value.as_str())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn leb(mut v: u64, out: &mut Vec<u8>) {
        loop {
            let mut byte = (v & 0x7f) as u8;
            v >>= 7;
            if v != 0 {
                byte |= 0x80;
            }
            out.push(byte);
            if v == 0 {
                break;
            }
        }
    }

    fn put_str(out: &mut Vec<u8>, s: &str) {
        leb(s.len() as u64, out);
        out.extend_from_slice(s.as_bytes());
    }

    /// 把 Unix 毫秒写成 .NET Ticks 的 8 字节小端。
    fn ticks(ms: i64) -> [u8; 8] {
        let t: i128 = (ms as i128) * 10_000 + 621_355_968_000_000_000;
        (t as u64).to_le_bytes()
    }

    /// 一条最小但字段齐全的媒体记录。
    fn record(designation: u8, path: &str, play: u16, last_played_ms: Option<i64>) -> Vec<u8> {
        let mut out = Vec::new();
        out.push(designation);
        out.push(0); // status
        out.push(0); // unknown
        out.extend_from_slice(&play.to_le_bytes());
        out.extend_from_slice(&last_played_ms.map(ticks).unwrap_or([0u8; 8]));
        out.extend_from_slice(&0u16.to_le_bytes()); // skips
        put_str(&mut out, path);
        out.extend_from_slice(&1234i32.to_le_bytes()); // size
        out.extend_from_slice(&44100i32.to_le_bytes()); // sample rate
        out.push(1); // channel mode
        out.push(0); // bitrate type
        out.extend_from_slice(&320i16.to_le_bytes()); // bitrate
        out.extend_from_slice(&245i32.to_le_bytes()); // length
        out.extend_from_slice(&ticks(1_700_000_000_000)); // added
        out.extend_from_slice(&ticks(1_700_000_500_000)); // modified
        out.push(254); // 封面列表结束（>253）
        out.push(0); // tags_type
        out.push(1); // tag code 1
        put_str(&mut out, "夜航");
        out.push(2); // tag code 2
        put_str(&mut out, "某乐队");
        out.push(0); // tags 结束
        out
    }

    fn library(records: &[Vec<u8>], declared: u32, version: u8) -> Vec<u8> {
        let mut out = Vec::new();
        let head: u32 = (declared << 8) | version as u32;
        out.extend_from_slice(&head.to_le_bytes());
        for r in records {
            out.extend_from_slice(r);
        }
        out.push(1); // 结束记录
        out
    }

    #[test]
    fn header_carries_version_and_declared_count() {
        let bytes = library(&[], 3, 8);
        let lib = parse(&bytes).expect("应能解析空库");
        assert_eq!(lib.declared, 3);
        assert_eq!(lib.version, 8);
        assert_eq!(lib.records.len(), 0);
    }

    #[test]
    fn parses_one_record_with_dotnet_ticks() {
        let bytes = library(&[record(2, "F:\\Music\\a.flac", 7, Some(1_760_000_000_000))], 1, 8);
        let lib = parse(&bytes).expect("应能解析一条记录");
        assert_eq!(lib.records.len(), 1);
        let r = &lib.records[0];
        assert_eq!(r.path, "F:\\Music\\a.flac");
        assert_eq!(r.play_count, 7);
        assert_eq!(r.last_played_ms, Some(1_760_000_000_000));
        assert_eq!(r.added_ms, Some(1_700_000_000_000));
        assert_eq!(r.modified_ms, Some(1_700_000_500_000));
        assert_eq!(r.sample_rate, 44100);
        assert_eq!(r.bitrate_raw, 320);
        assert_eq!(r.track_length_raw, 245);
        assert_eq!(r.tags, vec![(1u8, "夜航".to_string()), (2u8, "某乐队".to_string())]);
        assert!(r.artwork.is_empty());
        assert!(r.cue.is_empty());
    }

    #[test]
    fn zero_ticks_is_no_date_instead_of_1970() {
        let bytes = library(&[record(2, "F:\\Music\\b.flac", 0, None)], 1, 8);
        let lib = parse(&bytes).unwrap();
        assert_eq!(lib.records[0].last_played_ms, None);
    }

    #[test]
    fn high_byte_of_ticks_is_repaired_to_dotnet_marker() {
        // 真实文件里最高字节是 0x08；这里故意抹掉，解析仍应给出正确毫秒。
        let ms = 1_760_000_000_000i64;
        let mut raw = ticks(ms);
        raw[7] = 0x00;
        let repaired = dotnet_ticks_to_ms(u64::from_le_bytes(raw));
        assert_eq!(repaired, Some(ms));
    }

    #[test]
    fn unknown_designation_is_an_error_not_a_guess() {
        let ok = library(&[record(9, "x.flac", 0, None)], 1, 8);
        assert!(parse(&ok).is_ok(), "2..=9 都是合法媒体记录");
        let mut bad = Vec::new();
        bad.extend_from_slice(&8u32.to_le_bytes()); // version 8, declared 0
        bad.push(0); // 记录类型 0 不在 1..=9
        assert_eq!(parse(&bad).unwrap_err(), MblError::UnknownRecord(0));
    }

    #[test]
    fn bad_status_and_truncation_are_reported_with_reason() {
        let mut rec = record(2, "x.flac", 0, None);
        rec[1] = 9;
        let bytes = library(&[rec], 1, 8);
        assert_eq!(parse(&bytes).unwrap_err(), MblError::BadStatus(9));

        let mut short = library(&[], 0, 8);
        short.truncate(2);
        assert!(matches!(parse(&short).unwrap_err(), MblError::Truncated { .. }));
    }

    #[test]
    fn declared_count_mismatch_is_visible_not_hidden() {
        let bytes = library(&[record(2, "a.flac", 0, None)], 5, 8);
        let lib = parse(&bytes).unwrap();
        assert_eq!(lib.declared, 5);
        assert_eq!(lib.records.len(), 1, "声明的条数与实际解析条数都要露出来");
    }

    #[test]
    fn tag_map_is_injected_and_never_guessed() {
        let bytes = library(&[record(2, "a.flac", 0, None)], 1, 8);
        let lib = parse(&bytes).unwrap();
        let r = &lib.records[0];
        assert_eq!(tag_value(r, &TagMap::EMPTY, "title"), None, "没有映射表时不许猜字段名");
        let map = TagMap::with(&[(1, "title"), (2, "artist")]);
        assert_eq!(tag_value(r, &map, "title"), Some("夜航"));
        assert_eq!(tag_value(r, &map, "artist"), Some("某乐队"));
        assert_eq!(tag_value(r, &map, "album"), None);
    }

    /// 与 `record` 同形，但标签码由调用方给——用来测真实码（65/88 这些）。
    fn record_with(path: &str, tags: &[(u8, &str)]) -> Vec<u8> {
        let mut out = Vec::new();
        out.push(2);
        out.push(0);
        out.push(0);
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&[0u8; 8]);
        out.extend_from_slice(&0u16.to_le_bytes());
        put_str(&mut out, path);
        out.extend_from_slice(&0i32.to_le_bytes());
        out.extend_from_slice(&44100i32.to_le_bytes());
        out.push(1);
        out.push(0);
        out.extend_from_slice(&320i16.to_le_bytes());
        out.extend_from_slice(&200i32.to_le_bytes());
        out.extend_from_slice(&[0u8; 8]);
        out.extend_from_slice(&[0u8; 8]);
        out.push(254); // 封面段结束
        out.push(0); // tags_type
        for (code, value) in tags {
            out.push(*code);
            put_str(&mut out, value);
        }
        out.push(0);
        out
    }

    #[test]
    fn builtin_musicbee_map_labels_come_from_the_official_enum() {
        let map = TagMap::musicbee();
        assert_eq!(map.label(65), Some("TrackTitle"));
        assert_eq!(map.label(30), Some("Album"));
        assert_eq!(map.label(32), Some("Artist"));
        assert_eq!(map.label(88), Some("Year"));
        assert_eq!(map.label(200), None, "表外的码仍然不猜");
        assert!(!map.is_empty());
        assert!(TagMap::EMPTY.is_empty(), "空表就是空表，不许悄悄变成内置表");
        assert_eq!(TagMap::EMPTY.label(65), None, "没注入就不许有映射");
    }

    #[test]
    fn builtin_map_reads_a_real_code_65_title() {
        let bytes = library(&[record_with("F:\\Music\\a.flac", &[(65, "夜航"), (88, "1998")])], 1, 8);
        let lib = parse(&bytes).unwrap();
        let record = &lib.records[0];
        let map = TagMap::musicbee();
        assert_eq!(tag_value(record, &map, "TrackTitle"), Some("夜航"));
        assert_eq!(tag_value(record, &map, "Year"), Some("1998"));
        assert_eq!(tag_value(record, &map, "Album"), None);
    }

    #[test]
    fn overrides_win_over_the_builtin_table() {
        let map = TagMap::musicbee().with_overrides(&[(65, "本地改名")]);
        assert_eq!(map.label(65), Some("本地改名"), "覆盖优先");
        assert_eq!(map.label(88), Some("Year"), "没覆盖的仍走内置表");
        assert!(map.with_overrides(&[]).label(65).is_some());
    }

    #[test]
    fn windows_paths_map_onto_a_mounted_root_case_insensitively() {
        assert_eq!(
            map_windows_path("F:\\Music\\Artist\\01.flac", "f:/music", "/Volumes/Music"),
            Some("/Volumes/Music/Artist/01.flac".to_string())
        );
        assert_eq!(
            map_windows_path("\\\\NAS\\music\\x.flac", "\\\\nas\\music", "/mnt/nas"),
            Some("/mnt/nas/x.flac".to_string()),
            "UNC 路径也要能落到挂载点"
        );
        assert_eq!(
            map_windows_path("G:\\Other\\x.flac", "F:\\Music", "/mnt/music"),
            None,
            "根不匹配就返回 None，交给上层显示为未匹配"
        );
        assert_eq!(
            map_windows_path("F:\\Music2\\x.flac", "F:\\Music", "/mnt/music"),
            None,
            "段边界：Music2 不是 Music 的子路径"
        );
    }

    #[test]
    fn plan_splits_matched_and_unmatched_and_keeps_play_counts() {
        let bytes = library(
            &[
                record(2, "F:\\Music\\A\\01.flac", 12, Some(1_760_000_000_000)),
                record(2, "G:\\Other\\02.flac", 3, None),
            ],
            2,
            8,
        );
        let lib = parse(&bytes).unwrap();
        let plan = plan(&lib.records, "F:\\Music", "/mnt/music");
        assert_eq!(plan.matched.len(), 1);
        assert_eq!(plan.matched[0].posix_path, "/mnt/music/A/01.flac");
        assert_eq!(plan.matched[0].play_count, 12);
        assert_eq!(plan.unmatched, vec!["G:\\Other\\02.flac".to_string()]);
    }

    #[test]
    fn a_library_across_two_windows_drives_maps_with_two_mounts() {
        let bytes = library(
            &[
                record_with("F:\\Music\\A\\01.flac", &[]),
                record_with("G:\\Archive\\B\\02.flac", &[]),
                record_with("H:\\Nowhere\\03.flac", &[]),
            ],
            3,
            8,
        );
        let lib = parse(&bytes).unwrap();
        let mounts = [
            Mount::new("F:\\Music", "/Volumes/F-Music"),
            Mount::new("G:\\Archive", "/Volumes/G-Archive"),
        ];
        let plan = plan_multi(&lib.records, &mounts);
        assert_eq!(plan.matched.len(), 2, "两个盘各命中一条");
        assert_eq!(plan.matched[0].posix_path, "/Volumes/F-Music/A/01.flac");
        assert_eq!(plan.matched[1].posix_path, "/Volumes/G-Archive/B/02.flac");
        assert_eq!(plan.unmatched, vec!["H:\\Nowhere\\03.flac".to_string()], "第三个盘没给挂载点，如实报未匹配");
    }

    #[test]
    fn the_more_specific_root_wins_regardless_of_input_order() {
        let bytes = library(&[record_with("F:\\Music\\A\\01.flac", &[])], 1, 8);
        let lib = parse(&bytes).unwrap();
        // 故意把更宽的根放前面：结果必须是更具体的那个赢。
        let mounts = [Mount::new("F:\\", "/Volumes/F"), Mount::new("F:\\Music", "/Volumes/Music")];
        let plan = plan_multi(&lib.records, &mounts);
        assert_eq!(plan.matched[0].posix_path, "/Volumes/Music/A/01.flac");
    }

    #[test]
    fn windows_roots_counts_each_drive_and_sorts_by_count() {
        let bytes = library(
            &[
                record_with("G:\\Archive\\x.flac", &[]),
                record_with("F:\\Music\\A\\01.flac", &[]),
                record_with("f:\\Music\\A\\02.flac", &[]),
                record_with("\\\\NAS\\music\\n.flac", &[]),
            ],
            4,
            8,
        );
        let lib = parse(&bytes).unwrap();
        let roots = windows_roots(&lib.records);
        assert_eq!(roots[0], (r"F:\Music".to_string(), 2), "大小写不同算同一个根，且条数最多排第一");
        assert!(roots.iter().any(|(r, c)| r == r"G:\Archive" && *c == 1));
        assert!(roots.iter().any(|(r, c)| r == r"\\NAS\music" && *c == 1));
    }

    #[test]
    fn guess_root_handles_drive_roots_and_unc() {
        assert_eq!(guess_root(r"F:\Music\Artist\01.flac"), r"F:\Music");
        assert_eq!(guess_root(r"F:\01.flac"), r"F:");
        assert_eq!(guess_root(r"\\NAS\music\track.flac"), r"\\NAS\music");
        assert_eq!(guess_root(""), "");
    }

    #[test]
    fn play_count_never_goes_backwards() {
        assert_eq!(merge_play_count(10, 3), 10, "Awake 里新听的不能被旧库冲掉");
        assert_eq!(merge_play_count(3, 10), 10);
        assert_eq!(merge_play_count(0, 0), 0);
    }
}
