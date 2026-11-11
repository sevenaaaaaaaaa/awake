//! The decoder/producer owns disk IO. The callback consumes a bounded, lock-free PCM queue.
use awake_core::{
    decode,
    eq::{EqCurve, Equalizer},
    pipeline::{PcmFrame, Sequence},
};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use parking_lot::Mutex;
use rtrb::{Consumer, Producer, RingBuffer};
use serde::Serialize;
use std::{
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};

#[derive(Clone)]
pub struct QueueTrack {
    pub id: String,
    pub path: PathBuf,
    pub opener: Option<awake_core::pipeline::DecoderFactory>,
    pub duration: f64,
    pub sample_rate: u32,
}
#[derive(Clone, Default, Serialize)]
pub struct Status {
    pub queue_ids: Vec<String>,
    pub eq_preamp: f32,
    pub processed: bool,
    pub tags: decode::StreamTags,
    pub source_bits: u32,
    pub codec: String,
    pub state: String,
    pub current: Option<String>,
    pub position: f64,
    pub duration: f64,
    pub device: String,
    pub output_rate: u32,
    pub source_rate: u32,
    pub error: Option<String>,
    pub queue_index: usize,
    pub buffered_frames: usize,
    pub buffer_capacity_frames: usize,
    pub underruns: usize,
    pub startup_ms: u64,
    pub streaming: bool,
}
struct SeekRequest {
    index: usize,
    seconds: f64,
}
#[derive(Clone, Copy)]
struct Frame {
    pcm: PcmFrame,
    epoch: u64,
}
#[derive(Clone, Copy)]
struct End {
    index: usize,
    frames: usize,
    completed: bool,
    skipped: bool,
}
struct Session {
    tracks: Vec<QueueTrack>,
    formats: Mutex<Vec<Option<decode::TrackFormat>>>,
    info: Mutex<Status>,
    cancelled: AtomicBool,
    paused: AtomicBool,
    finished: AtomicBool,
    epoch: AtomicU64,
    ready_epoch: AtomicU64,
    request: Mutex<Option<SeekRequest>>,
    index: AtomicUsize,
    position: AtomicUsize,
    listened: AtomicUsize,
    decode_failed: AtomicBool,
    seeking: AtomicBool,
    producer_done: AtomicBool,
    terminal: AtomicBool,
    skipped: AtomicBool,
    buffered: AtomicUsize,
    underruns: AtomicUsize,
    startup_ms: AtomicU64,
    started: Instant,
    callback_error: AtomicUsize,
    drain_us: AtomicU64,
}
impl Session {
    fn new(tracks: Vec<QueueTrack>) -> Arc<Self> {
        let formats = Mutex::new(vec![None; tracks.len()]);
        Arc::new(Session {
            tracks,
            formats,
            info: Mutex::new(Status {
                state: "loading".into(),
                streaming: true,
                ..Status::default()
            }),
            cancelled: AtomicBool::new(false),
            paused: AtomicBool::new(false),
            finished: AtomicBool::new(false),
            epoch: AtomicU64::new(0),
            ready_epoch: AtomicU64::new(0),
            request: Mutex::new(None),
            index: AtomicUsize::new(0),
            position: AtomicUsize::new(0),
            listened: AtomicUsize::new(0),
            decode_failed: AtomicBool::new(false),
            seeking: AtomicBool::new(false),
            producer_done: AtomicBool::new(false),
            terminal: AtomicBool::new(false),
            skipped: AtomicBool::new(false),
            buffered: AtomicUsize::new(0),
            underruns: AtomicUsize::new(0),
            startup_ms: AtomicU64::new(0),
            started: Instant::now(),
            callback_error: AtomicUsize::new(0),
            drain_us: AtomicU64::new(0),
        })
    }
}
pub struct Player {
    session: Mutex<Option<Arc<Session>>>,
    pub curve: Arc<Mutex<EqCurve>>,
    pub volume: Arc<Mutex<f32>>,
}
impl Player {
    pub fn new() -> Self {
        Self {
            session: Mutex::new(None),
            curve: Arc::new(Mutex::new(EqCurve::flat())),
            volume: Arc::new(Mutex::new(0.7)),
        }
    }
    pub fn stop(&self) {
        if let Some(s) = self.session.lock().as_ref() {
            s.cancelled.store(true, Ordering::Release);
            s.info.lock().state = "stopped".into();
        }
    }
    pub fn stop_and_flush(&self) {
        self.stop();
        let session = self.session.lock().clone();
        if let Some(s) = session {
            let deadline = Instant::now() + Duration::from_millis(1000);
            while !s.finished.load(Ordering::Acquire) && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(5));
            }
        }
    }
    pub fn status(&self) -> Status {
        let session = self.session.lock().clone();
        let curve = self.curve.lock().clone();
        let Some(s) = session else {
            return Status {
                eq_preamp: curve.preamp,
                processed: !curve.is_flat(),
                state: "idle".into(),
                ..Status::default()
            };
        };
        let mut info = s.info.lock().clone();
        info.eq_preamp = curve.preamp;
        info.processed = !curve.is_flat();
        let index = s.index.load(Ordering::Acquire).min(s.tracks.len() - 1);
        info.queue_ids = s.tracks.iter().map(|t| t.id.clone()).collect();
        info.current = Some(s.tracks[index].id.clone());
        info.queue_index = index;
        info.duration = s.tracks[index].duration;
        info.source_rate = s.tracks[index].sample_rate;
        if let Some(format) = &s.formats.lock()[index] {
            info.duration = format.duration_secs.unwrap_or(info.duration);
            info.source_rate = format.sample_rate;
            info.source_bits = format.bits_per_sample.unwrap_or(0);
            info.codec = format.codec.clone();
            info.tags = format.tags.clone();
        }
        if info.output_rate > 0 {
            info.position = s.position.load(Ordering::Relaxed) as f64 / info.output_rate as f64;
        }
        if s.paused.load(Ordering::Relaxed) && info.state == "playing" {
            info.state = "paused".into();
        } else if s.seeking.load(Ordering::Acquire) && info.state == "playing" {
            info.state = "buffering".into();
        }
        info.buffered_frames = s.buffered.load(Ordering::Relaxed);
        info.underruns = s.underruns.load(Ordering::Relaxed);
        info.startup_ms = s.startup_ms.load(Ordering::Relaxed);
        info
    }
    pub fn play_queue(
        &self,
        tracks: Vec<QueueTrack>,
        skip_previous: bool,
        mut on_end: impl FnMut(String, f64, bool, bool) + Send + 'static,
    ) -> Result<(), String> {
        if tracks.is_empty() {
            return Err("播放队列为空".into());
        }
        if let Some(old) = self.session.lock().as_ref() {
            old.skipped.store(skip_previous, Ordering::Relaxed);
        }
        self.stop();
        let session = Session::new(tracks);
        *self.session.lock() = Some(session.clone());
        let curve = self.curve.clone();
        let volume = self.volume.clone();
        std::thread::spawn(move || {
            if let Err(e) = run(&session, curve, volume, &mut on_end) {
                if !session.cancelled.load(Ordering::Acquire) {
                    let mut info = session.info.lock();
                    info.state = "error".into();
                    info.error = Some(e.to_string());
                }
            }
            session.finished.store(true, Ordering::Release);
        });
        Ok(())
    }
    pub fn pause(&self, paused: bool) {
        if let Some(s) = self.session.lock().as_ref() {
            s.paused.store(paused, Ordering::Release);
        }
    }
    pub fn seek(&self, seconds: f64) -> Result<(), String> {
        if !seconds.is_finite() || seconds < 0.0 {
            return Err("无效的播放位置".into());
        }
        let session = self.session.lock().clone().ok_or("尚未播放")?;
        if session.terminal.load(Ordering::Acquire) {
            return Err("曲目已结束，请重新播放".into());
        }
        let rate = session.info.lock().output_rate;
        if rate == 0 {
            return Err("音频尚未就绪".into());
        }
        let index = session.index.load(Ordering::Acquire);
        let duration = session.tracks[index].duration;
        let seconds = if duration > 0.0 {
            seconds.min((duration - 1.0 / rate as f64).max(0.0))
        } else {
            seconds
        };
        session.seeking.store(true, Ordering::Release);
        *session.request.lock() = Some(SeekRequest { index, seconds });
        session.producer_done.store(false, Ordering::Release);
        session.terminal.store(false, Ordering::Release);
        session
            .position
            .store((seconds * rate as f64).round() as usize, Ordering::Release);
        session.epoch.fetch_add(1, Ordering::AcqRel);
        Ok(())
    }
}

fn report(s: &Session, event: End, rate: u32, on_end: &mut impl FnMut(String, f64, bool, bool)) {
    if event.frames > 0 {
        on_end(
            s.tracks[event.index].id.clone(),
            event.frames as f64 / rate as f64,
            event.completed,
            event.skipped,
        );
    }
}
fn run(
    s: &Arc<Session>,
    curve: Arc<Mutex<EqCurve>>,
    volume: Arc<Mutex<f32>>,
    on_end: &mut impl FnMut(String, f64, bool, bool),
) -> anyhow::Result<()> {
    let openers: Vec<_> = s
        .tracks
        .iter()
        .map(|track| {
            track.opener.clone().unwrap_or_else(|| {
                let path = track.path.clone();
                Arc::new(move || decode::StreamDecoder::open(&path))
            })
        })
        .collect();
    let first = openers[0]()?.format;
    let device = cpal::default_host()
        .default_output_device()
        .ok_or_else(|| anyhow::anyhow!("没有可用的输出设备"))?;
    let config = device
        .supported_output_configs()?
        .find(|r| {
            r.channels() as usize == first.channels
                && r.min_sample_rate().0 <= first.sample_rate
                && first.sample_rate <= r.max_sample_rate().0
                && matches!(
                    r.sample_format(),
                    cpal::SampleFormat::F32 | cpal::SampleFormat::I16 | cpal::SampleFormat::U16
                )
        })
        .map(|r| r.with_sample_rate(cpal::SampleRate(first.sample_rate)))
        .unwrap_or(device.default_output_config()?);
    let rate = config.sample_rate().0;
    let channels = config.channels() as usize;
    anyhow::ensure!(channels <= 8 && channels > 0, "不支持输出设备的声道数");
    let remote = s.tracks.iter().any(|t| t.opener.is_some());
    let capacity = if remote {
        (rate as usize * 2).min(384000)
    } else {
        (rate as usize / 2).clamp(4096, 96000)
    };
    let (mut producer, consumer) = RingBuffer::new(capacity);
    let (events_out, mut events_in) = RingBuffer::new(1024);
    {
        let mut info = s.info.lock();
        info.output_rate = rate;
        info.device = device.name().unwrap_or_else(|_| "系统默认输出".into());
        info.buffer_capacity_frames = capacity;
    }
    {
        let current = curve.lock().clone();
        let protected = crate::experience::with_correction(&current.gains, &current, rate)
            .map_err(anyhow::Error::msg)?;
        *curve.lock() = protected;
    }
    let render = Renderer::new(
        s.clone(),
        consumer,
        events_out,
        curve,
        volume,
        rate,
        channels,
    );
    let stream = match config.sample_format() {
        cpal::SampleFormat::F32 => build::<f32>(&device, &config.config(), render)?,
        cpal::SampleFormat::I16 => build::<i16>(&device, &config.config(), render)?,
        cpal::SampleFormat::U16 => build::<u16>(&device, &config.config(), render)?,
        other => anyhow::bail!("暂不支持 {other:?} 输出"),
    };
    let mut sequence = Sequence::from_openers(openers.clone(), rate, channels, 0, 0.0)?;
    let mut epoch = 0;
    let mut prepared = 0usize;
    let prebuffer = if remote {
        rate as usize / 2
    } else {
        rate as usize / 10
    };
    let mut started = false;
    let mut error = None;
    let mut eof = false;
    'produce: loop {
        while let Ok(e) = events_in.pop() {
            report(s, e, rate, on_end);
        }
        if s.cancelled.load(Ordering::Acquire) {
            break;
        }
        if s.callback_error.load(Ordering::Acquire) != 0 {
            error = Some(anyhow::anyhow!("音频输出回调失败或事件缓冲溢出"));
            break;
        }
        if epoch != s.epoch.load(Ordering::Acquire) {
            let (next_epoch, request) = {
                let mut pending = s.request.lock();
                (s.epoch.load(Ordering::Acquire), pending.take())
            };
            epoch = next_epoch;
            prepared = 0;
            if let Some(request) = request {
                sequence = Sequence::from_openers(
                    openers.clone(),
                    rate,
                    channels,
                    request.index,
                    request.seconds,
                )?;
                eof = false;
                error = None;
                s.decode_failed.store(false, Ordering::Release);
                s.producer_done.store(false, Ordering::Release);
                s.terminal.store(false, Ordering::Release);
            }
        }
        if eof {
            if !started {
                stream.play()?;
                started = true;
                s.info.lock().state = "playing".into();
            }
            if s.terminal.load(Ordering::Acquire) {
                break;
            }
            std::thread::sleep(Duration::from_millis(1));
            continue;
        }
        let block = match sequence.next_block() {
            Ok(Some(b)) => b,
            result => {
                if let Err(e) = result {
                    error = Some(e);
                    s.decode_failed.store(true, Ordering::Release);
                }
                eof = true;
                if epoch == s.epoch.load(Ordering::Acquire) {
                    s.producer_done.store(true, Ordering::Release);
                    s.ready_epoch.store(epoch, Ordering::Release);
                }
                continue;
            }
        };
        {
            let mut formats = s.formats.lock();
            for (i, format) in sequence.formats.iter().enumerate() {
                if let Some(format) = format {
                    if formats[i].is_none() {
                        formats[i] = Some(format.clone());
                    }
                }
            }
        }
        for pcm in block {
            loop {
                if s.cancelled.load(Ordering::Acquire) {
                    break 'produce;
                }
                if epoch != s.epoch.load(Ordering::Acquire) {
                    continue 'produce;
                }
                while let Ok(e) = events_in.pop() {
                    report(s, e, rate, on_end);
                }
                if producer.slots() > 0 {
                    producer.push(Frame { pcm, epoch }).unwrap();
                    prepared += 1;
                    if prepared >= prebuffer {
                        s.ready_epoch.store(epoch, Ordering::Release);
                    }
                    break;
                }
                if !started {
                    stream.play()?;
                    started = true;
                    s.info.lock().state = "playing".into();
                }
                std::thread::sleep(Duration::from_millis(1));
            }
            s.buffered
                .store(capacity - producer.slots(), Ordering::Relaxed);
            if !started && capacity - producer.slots() >= prebuffer {
                stream.play()?;
                started = true;
                s.info.lock().state = "playing".into();
            }
        }
    }
    finish(s, stream, &mut events_in, rate, error, on_end)
}

fn finish(
    s: &Session,
    stream: cpal::Stream,
    events: &mut Consumer<End>,
    rate: u32,
    error: Option<anyhow::Error>,
    on_end: &mut impl FnMut(String, f64, bool, bool),
) -> anyhow::Result<()> {
    if s.terminal.load(Ordering::Acquire) {
        let deadline =
            Instant::now() + Duration::from_micros(s.drain_us.load(Ordering::Relaxed).min(500000));
        while !s.cancelled.load(Ordering::Acquire) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(2));
        }
    }
    drop(stream);
    while let Ok(e) = events.pop() {
        report(s, e, rate, on_end);
    }
    if !s.terminal.load(Ordering::Acquire) {
        report(
            s,
            End {
                index: s.index.load(Ordering::Acquire),
                frames: s.listened.load(Ordering::Acquire),
                completed: false,
                skipped: s.skipped.load(Ordering::Relaxed),
            },
            rate,
            on_end,
        );
    }
    if s.callback_error.load(Ordering::Relaxed) != 0 {
        anyhow::bail!("输出设备停止响应");
    }
    if let Some(error) = error {
        return Err(error);
    }
    if !s.cancelled.load(Ordering::Acquire) {
        s.info.lock().state = "ended".into();
    }
    Ok(())
}

struct Renderer {
    session: Arc<Session>,
    consumer: Consumer<Frame>,
    events: Producer<End>,
    curve: Arc<Mutex<EqCurve>>,
    volume: Arc<Mutex<f32>>,
    eq: Equalizer,
    next_eq: Equalizer,
    applied: EqCurve,
    channels: usize,
    rate: u32,
    epoch: u64,
    index: Option<usize>,
    listened: usize,
    gain: f32,
    fade: usize,
    fade_frames: usize,
    pending_shortage: bool,
}
impl Renderer {
    fn new(
        session: Arc<Session>,
        consumer: Consumer<Frame>,
        events: Producer<End>,
        curve: Arc<Mutex<EqCurve>>,
        volume: Arc<Mutex<f32>>,
        rate: u32,
        channels: usize,
    ) -> Self {
        let applied = curve.lock().clone();
        let mut eq = Equalizer::new(rate as f32, channels);
        eq.apply_curve(&applied);
        Self {
            session,
            consumer,
            events,
            curve,
            volume,
            eq,
            next_eq: Equalizer::new(rate as f32, channels),
            applied,
            channels,
            rate,
            epoch: 0,
            index: None,
            listened: 0,
            gain: 0.0,
            fade: 0,
            fade_frames: (rate as usize / 50).max(1),
            pending_shortage: false,
        }
    }
    fn end(&mut self, completed: bool) {
        if let Some(index) = self.index {
            if self
                .events
                .push(End {
                    index,
                    frames: self.listened,
                    completed,
                    skipped: false,
                })
                .is_err()
            {
                self.session.callback_error.store(2, Ordering::Release);
            }
        }
    }
    fn render<T: cpal::SizedSample + cpal::FromSample<f32>>(&mut self, output: &mut [T]) {
        output.fill(T::from_sample(0.0));
        let s = self.session.clone();
        if s.cancelled.load(Ordering::Acquire) || s.terminal.load(Ordering::Acquire) {
            return;
        }
        let epoch = s.epoch.load(Ordering::Acquire);
        if epoch != self.epoch {
            self.epoch = epoch;
            self.eq.reset();
            self.next_eq.reset();
            self.gain = 0.0;
            self.pending_shortage = false;
        }
        // Free obsolete frames even while the producer is preparing a seek. Keep
        // new frames queued until enough audio (or the entire short tail) is ready.
        while self.consumer.peek().is_ok_and(|frame| frame.epoch != epoch) {
            let _ = self.consumer.pop();
        }
        if s.ready_epoch.load(Ordering::Acquire) != epoch {
            s.buffered.store(self.consumer.slots(), Ordering::Relaxed);
            return;
        }
        if let Some(next) = self.curve.try_lock() {
            if *next != self.applied {
                self.next_eq.reset();
                self.next_eq.apply_curve(&next);
                self.applied = next.clone();
                self.fade = self.fade_frames;
            }
        }
        let paused = s.paused.load(Ordering::Acquire);
        let target = if paused {
            0.0
        } else {
            self.volume.try_lock().map(|v| *v).unwrap_or(self.gain)
        };
        if paused && self.gain <= 0.0 {
            return;
        }
        let mut shortage = false;
        for dst in output.chunks_exact_mut(self.channels) {
            if paused && self.gain <= 0.0 {
                break;
            }
            let frame = loop {
                match self.consumer.pop() {
                    Ok(frame) if frame.epoch == epoch => break Some(frame.pcm),
                    Ok(_) => continue,
                    Err(_) => break None,
                }
            };
            let Some(frame) = frame else {
                if s.producer_done.load(Ordering::Acquire) {
                    self.pending_shortage = false;
                    if !s.terminal.swap(true, Ordering::AcqRel) {
                        self.end(!s.decode_failed.load(Ordering::Acquire));
                    }
                } else if !s.seeking.load(Ordering::Acquire) {
                    shortage = true;
                }
                break;
            };
            if self.pending_shortage {
                s.underruns.fetch_add(1, Ordering::Relaxed);
                self.pending_shortage = false;
            }
            s.seeking.store(false, Ordering::Release);
            if self.index != Some(frame.track) {
                self.end(true);
                self.index = Some(frame.track);
                self.listened = 0;
                s.index.store(frame.track, Ordering::Release);
            }
            let mut dry = frame.samples;
            let mut wet = frame.samples;
            self.eq.process_interleaved(&mut dry[..self.channels]);
            if self.fade > 0 {
                self.next_eq.process_interleaved(&mut wet[..self.channels]);
                let alpha = 1.0 - self.fade as f32 / self.fade_frames as f32;
                for c in 0..self.channels {
                    dry[c] = dry[c] * (1.0 - alpha) + wet[c] * alpha;
                }
                self.fade -= 1;
                if self.fade == 0 {
                    std::mem::swap(&mut self.eq, &mut self.next_eq);
                }
            }
            self.gain += (target - self.gain).clamp(
                -1.0 / (self.rate as f32 * 0.015),
                1.0 / (self.rate as f32 * 0.015),
            );
            for (c, dst) in dst.iter_mut().enumerate() {
                *dst = T::from_sample((dry[c] * self.gain).clamp(-1.0, 1.0));
            }
            self.listened += 1;
            s.position
                .store(frame.position as usize + 1, Ordering::Relaxed);
            if s.startup_ms.load(Ordering::Relaxed) == 0 {
                s.startup_ms.store(
                    s.started.elapsed().as_millis().max(1) as u64,
                    Ordering::Relaxed,
                );
            }
        }
        s.listened.store(self.listened, Ordering::Release);
        s.buffered.store(self.consumer.slots(), Ordering::Relaxed);
        if shortage {
            self.pending_shortage = true;
        }
    }
}
fn build<T: cpal::SizedSample + cpal::FromSample<f32>>(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    mut renderer: Renderer,
) -> Result<cpal::Stream, cpal::BuildStreamError> {
    let session = renderer.session.clone();
    let rate = config.sample_rate.0;
    let channels = config.channels as usize;
    device.build_output_stream(
        config,
        move |output: &mut [T], info| {
            let times = info.timestamp();
            let latency = times
                .playback
                .duration_since(&times.callback)
                .unwrap_or_default();
            renderer.session.drain_us.store(
                latency.as_micros() as u64
                    + (output.len() / channels) as u64 * 1000000 / rate as u64,
                Ordering::Relaxed,
            );
            renderer.render(output);
        },
        move |_| {
            session.callback_error.store(1, Ordering::Release);
        },
        None,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_audio;
    #[test]
    fn invalid_requests_do_not_start_an_output_stream() {
        let player = Player::new();
        assert!(player.seek(f64::NAN).is_err());
        assert!(player.seek(1.0).is_err());
        assert!(player.play_queue(vec![], true, |_, _, _, _| {}).is_err());
        assert_eq!(player.status().state, "idle");
    }
    #[test]
    #[ignore = "uses the real default CoreAudio output, at zero volume"]
    fn real_output_streaming_queue_pause_seek_and_eof() {
        let dir = test_audio::directory();
        let a = dir.join("a.wav");
        let b = dir.join("b.wav");
        let samples: Vec<i16> = (0..96000)
            .flat_map(|i| {
                let v = ((i as f64 * 0.11).sin() * 10000.0) as i16;
                [v, v]
            })
            .collect();
        test_audio::wav(&a, 48000, 2, &samples);
        test_audio::wav(&b, 48000, 2, &samples);
        let player = Player::new();
        *player.volume.lock() = 0.0;
        let (tx, rx) = std::sync::mpsc::channel();
        player
            .play_queue(
                vec![
                    QueueTrack {
                        id: "a".into(),
                        path: a,
                        opener: None,
                        duration: 2.0,
                        sample_rate: 48000,
                    },
                    QueueTrack {
                        id: "b".into(),
                        path: b,
                        opener: None,
                        duration: 2.0,
                        sample_rate: 48000,
                    },
                ],
                true,
                move |id, secs, completed, skipped| {
                    tx.send((id, secs, completed, skipped)).unwrap();
                },
            )
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while player.status().position < 0.1 {
            assert!(Instant::now() < deadline, "{:?}", player.status().error);
            std::thread::sleep(Duration::from_millis(10));
        }
        player.pause(true);
        std::thread::sleep(Duration::from_millis(100));
        let position = player.status().position;
        std::thread::sleep(Duration::from_millis(100));
        assert_eq!(player.status().position, position);
        player.seek(1.7).unwrap();
        player.pause(false);
        let first = rx.recv_timeout(Duration::from_secs(5)).unwrap();
        let second = rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(first.0, "a");
        assert!(first.1 < 1.0 && first.2 && !first.3);
        assert_eq!(second.0, "b");
        assert!((second.1 - 2.0).abs() < 0.001 && second.2);
        while player.status().state != "ended" {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(10));
        }
        let status = player.status();
        assert!(status.streaming);
        assert_eq!(status.underruns, 0);
        assert!(status.startup_ms < 1500);
        println!(
            "streaming startup={}ms capacity={}frames underruns={} position={}s",
            status.startup_ms, status.buffer_capacity_frames, status.underruns, status.position
        );
        std::fs::remove_dir_all(dir).unwrap();
    }
}

#[cfg(test)]
mod soak_tests {
    use super::*;
    fn rss() -> usize {
        std::process::Command::new("ps")
            .args(["-o", "rss=", "-p", &std::process::id().to_string()])
            .output()
            .ok()
            .and_then(|o| String::from_utf8(o.stdout).ok())
            .and_then(|s| s.trim().parse().ok())
            .unwrap_or(0)
    }
    #[test]
    #[ignore = "five-minute silent CoreAudio soak; generates a sparse two-hour WAV"]
    fn five_minute_long_track_memory_and_underruns() {
        let dir = crate::test_audio::directory();
        let path = dir.join("long.wav");
        crate::test_audio::sparse(&path, 48000, 2, 7200);
        let player = Player::new();
        *player.volume.lock() = 0.0;
        player
            .play_queue(
                vec![QueueTrack {
                    id: "long".into(),
                    path,
                    opener: None,
                    duration: 7200.0,
                    sample_rate: 48000,
                }],
                true,
                |_, _, _, _| {},
            )
            .unwrap();
        let start = Instant::now();
        let mut base = 0;
        let mut peak = 0;
        while start.elapsed() < Duration::from_secs(300) {
            std::thread::sleep(Duration::from_secs(5));
            let status = player.status();
            assert!(status.error.is_none(), "{:?}", status.error);
            assert!(status.buffered_frames <= status.buffer_capacity_frames);
            let memory = rss();
            if base == 0 {
                base = memory;
            }
            peak = peak.max(memory);
            if start.elapsed().as_secs() % 30 < 5 {
                println!(
                    "soak t={}s position={:.1}s rss={}KB peak={}KB underruns={}",
                    start.elapsed().as_secs(),
                    status.position,
                    memory,
                    peak,
                    status.underruns
                );
            }
        }
        let status = player.status();
        player.stop_and_flush();
        assert!(status.position > 295.0);
        assert_eq!(status.underruns, 0);
        assert!(
            base > 0 && peak - base < 16384,
            "RSS grew {}KB",
            peak - base
        );
        println!(
            "SOAK_PASS seconds={:.1} startup={}ms baseline={}KB peak={}KB delta={}KB",
            status.position,
            status.startup_ms,
            base,
            peak,
            peak - base
        );
        std::fs::remove_dir_all(dir).unwrap();
    }
}

#[cfg(test)]
mod callback_tests {
    use super::*;
    #[test]
    fn seek_discards_old_audio_and_waits_for_prebuffer_without_losing_new_frames() {
        let session = Session::new(vec![QueueTrack {
            id: "seek".into(),
            path: PathBuf::new(),
            opener: None,
            duration: 10.0,
            sample_rate: 48000,
        }]);
        let (mut producer, consumer) = RingBuffer::new(16);
        let (events, _) = RingBuffer::new(16);
        let mut render = Renderer::new(
            session.clone(),
            consumer,
            events,
            Arc::new(Mutex::new(EqCurve::flat())),
            Arc::new(Mutex::new(1.0)),
            48000,
            2,
        );
        let pcm = PcmFrame {
            samples: [0.2; 8],
            track: 0,
            position: 240000,
        };
        producer.push(Frame { epoch: 0, pcm }).unwrap();
        producer.push(Frame { epoch: 1, pcm }).unwrap();
        session.seeking.store(true, Ordering::Release);
        session.epoch.store(1, Ordering::Release);
        let mut output = [1.0_f32; 2];
        crate::allocation_audit::start();
        render.render(&mut output);
        let allocations = crate::allocation_audit::finish();
        assert_eq!(allocations, 0);
        assert_eq!(output, [0.0; 2]);
        assert_eq!(render.consumer.slots(), 1, "new audio must stay queued");
        assert_eq!(session.position.load(Ordering::Relaxed), 0);
        // A short end-of-file tail may be released before the usual threshold.
        session.producer_done.store(true, Ordering::Release);
        session.ready_epoch.store(1, Ordering::Release);
        render.render(&mut output);
        assert_eq!(session.position.load(Ordering::Relaxed), 240001);
        assert!(output[0] > 0.0);
        assert_eq!(session.underruns.load(Ordering::Relaxed), 0);
        assert!(!session.seeking.load(Ordering::Relaxed));
    }
    #[test]
    fn eof_padding_is_not_starvation_but_interrupted_audio_is_counted() {
        for eof in [false, true] {
            let session = Session::new(vec![QueueTrack {
                id: "test".into(),
                path: PathBuf::new(),
                opener: None,
                duration: 1.0,
                sample_rate: 48000,
            }]);
            let (mut producer, consumer) = RingBuffer::new(16);
            let (events, _) = RingBuffer::new(16);
            let mut render = Renderer::new(
                session.clone(),
                consumer,
                events,
                Arc::new(Mutex::new(EqCurve::flat())),
                Arc::new(Mutex::new(1.0)),
                48000,
                2,
            );
            let mut samples = [0.0; 8];
            samples[0] = 0.2;
            samples[1] = 0.2;
            producer
                .push(Frame {
                    epoch: 0,
                    pcm: PcmFrame {
                        samples,
                        track: 0,
                        position: 0,
                    },
                })
                .unwrap();
            render.render(&mut [0.0_f32; 4]);
            assert_eq!(session.underruns.load(Ordering::Relaxed), 0);
            if eof {
                session.producer_done.store(true, Ordering::Release);
            } else {
                producer
                    .push(Frame {
                        epoch: 0,
                        pcm: PcmFrame {
                            samples,
                            track: 0,
                            position: 1,
                        },
                    })
                    .unwrap();
            }
            render.render(&mut [0.0_f32; 2]);
            assert_eq!(
                session.underruns.load(Ordering::Relaxed),
                if eof { 0 } else { 1 }
            );
        }
    }
    #[test]
    fn callback_has_no_allocations_or_gap_at_track_boundary_and_eq_change() {
        let session = Session::new(vec![
            QueueTrack {
                id: "a".into(),
                path: PathBuf::new(),
                opener: None,
                duration: 1.0,
                sample_rate: 48000,
            },
            QueueTrack {
                id: "b".into(),
                path: PathBuf::new(),
                opener: None,
                duration: 1.0,
                sample_rate: 48000,
            },
        ]);
        let (mut producer, consumer) = RingBuffer::new(2048);
        let (events, mut completed) = RingBuffer::new(16);
        let curve = Arc::new(Mutex::new(EqCurve::flat()));
        let volume = Arc::new(Mutex::new(1.0));
        let mut render = Renderer::new(
            session.clone(),
            consumer,
            events,
            curve.clone(),
            volume,
            48000,
            2,
        );
        render.gain = 1.0;
        for i in 0..2048 {
            let mut samples = [0.0; 8];
            samples[0] = 0.2;
            samples[1] = -0.2;
            producer
                .push(Frame {
                    epoch: 0,
                    pcm: PcmFrame {
                        samples,
                        track: if i < 513 { 0 } else { 1 },
                        position: if i < 513 { i } else { i - 513 } as u64,
                    },
                })
                .unwrap();
        }
        let mut output = [0.0_f32; 2048];
        crate::allocation_audit::start();
        render.render(&mut output);
        let allocations = crate::allocation_audit::finish();
        assert_eq!(allocations, 0);
        assert!(output.chunks_exact(2).all(|f| f == [0.2, -0.2]));
        let event = completed.pop().unwrap();
        assert_eq!(event.index, 0);
        assert_eq!(event.frames, 513);
        assert!(event.completed);
        let mut next = EqCurve::flat();
        next.gains[17] = 3.0;
        next.filters[0] = awake_core::parametric::Filter {
            frequency: 80.0,
            gain_db: 2.0,
            ..Default::default()
        };
        next.filter_count = 1;
        *curve.lock() = next;
        crate::allocation_audit::start();
        render.render(&mut output);
        let allocations = crate::allocation_audit::finish();
        assert_eq!(allocations, 0);
        assert!(output.iter().all(|s| s.is_finite()));
    }
}
