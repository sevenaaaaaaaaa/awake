//! Self-contained audio fixtures; no optional external DemoMusic dependency.
use std::{
    io::Write,
    path::{Path, PathBuf},
};
pub fn directory() -> PathBuf {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let id = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let path = std::env::temp_dir().join(format!(
        "awake-audio-test-{}-{stamp}-{id}",
        std::process::id()
    ));
    std::fs::create_dir(&path).unwrap();
    path
}
pub fn wav(path: &Path, rate: u32, channels: u16, samples: &[i16]) {
    let mut file = std::fs::File::create(path).unwrap();
    header(&mut file, rate, channels, (samples.len() * 2) as u32);
    let bytes: Vec<_> = samples.iter().flat_map(|s| s.to_le_bytes()).collect();
    file.write_all(&bytes).unwrap();
}
pub fn sparse(path: &Path, rate: u32, channels: u16, seconds: u32) {
    let mut file = std::fs::File::create(path).unwrap();
    let len = rate * channels as u32 * 2 * seconds;
    header(&mut file, rate, channels, len);
    file.set_len(44 + len as u64).unwrap();
}
fn header(file: &mut std::fs::File, rate: u32, channels: u16, len: u32) {
    file.write_all(b"RIFF").unwrap();
    file.write_all(&(len + 36).to_le_bytes()).unwrap();
    file.write_all(b"WAVEfmt ").unwrap();
    file.write_all(&16_u32.to_le_bytes()).unwrap();
    file.write_all(&1_u16.to_le_bytes()).unwrap();
    file.write_all(&channels.to_le_bytes()).unwrap();
    file.write_all(&rate.to_le_bytes()).unwrap();
    file.write_all(&(rate * channels as u32 * 2).to_le_bytes())
        .unwrap();
    file.write_all(&(channels * 2).to_le_bytes()).unwrap();
    file.write_all(&16_u16.to_le_bytes()).unwrap();
    file.write_all(b"data").unwrap();
    file.write_all(&len.to_le_bytes()).unwrap();
}
