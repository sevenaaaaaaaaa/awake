//! Bounded streaming queue renderer. Compatible tracks share a sinc resampler's history.
use crate::decode::{StreamDecoder, TrackFormat};
use anyhow::Result;
use rubato::{
    Resampler, SincFixedIn, SincInterpolationParameters, SincInterpolationType, WindowFunction,
};
use std::{collections::VecDeque, path::PathBuf, sync::Arc};
pub type DecoderFactory = Arc<dyn Fn() -> Result<StreamDecoder> + Send + Sync>;

pub const MAX_CHANNELS: usize = 8;
const CHUNK: usize = 1024;

#[derive(Clone, Copy, Debug)]
pub struct PcmFrame {
    pub samples: [f32; MAX_CHANNELS],
    pub track: usize,
    pub position: u64,
}

struct Converter {
    resampler: Option<SincFixedIn<f32>>,
    pending: VecDeque<f32>,
    channels: usize,
    input_rate: u32,
    output_rate: u32,
    input_frames: u64,
    output_frames: u64,
}
impl Converter {
    fn new(input_rate: u32, output_rate: u32, channels: usize) -> Result<Self> {
        let resampler = if input_rate == output_rate {
            None
        } else {
            Some(SincFixedIn::new(
                output_rate as f64 / input_rate as f64,
                1.0,
                SincInterpolationParameters {
                    sinc_len: 256,
                    f_cutoff: 0.95,
                    interpolation: SincInterpolationType::Linear,
                    oversampling_factor: 256,
                    window: WindowFunction::BlackmanHarris2,
                },
                CHUNK,
                channels,
            )?)
        };
        Ok(Self {
            resampler,
            pending: VecDeque::with_capacity(CHUNK * channels * 2),
            channels,
            input_rate,
            output_rate,
            input_frames: 0,
            output_frames: 0,
        })
    }
    fn expected(&self) -> u64 {
        (self.input_frames as f64 * self.output_rate as f64 / self.input_rate as f64).round() as u64
    }
    fn block(&mut self) -> Result<Vec<f32>> {
        let mut planar = vec![vec![0.0; CHUNK]; self.channels];
        for i in 0..CHUNK {
            for channel in &mut planar {
                channel[i] = self.pending.pop_front().unwrap_or(0.0);
            }
        }
        let converted = self.resampler.as_mut().unwrap().process(&planar, None)?;
        let frames = converted[0].len();
        let mut out = Vec::with_capacity(frames * self.channels);
        for i in 0..frames {
            for channel in &converted {
                out.push(channel[i]);
            }
        }
        self.output_frames += frames as u64;
        Ok(out)
    }
    fn push(&mut self, pcm: &[f32]) -> Result<Vec<f32>> {
        self.input_frames += (pcm.len() / self.channels) as u64;
        if self.resampler.is_none() {
            self.output_frames = self.input_frames;
            return Ok(pcm.to_vec());
        }
        self.pending.extend(pcm);
        let mut out = Vec::new();
        while self.pending.len() >= CHUNK * self.channels {
            out.extend(self.block()?);
        }
        Ok(out)
    }
    fn finish(&mut self) -> Result<Vec<f32>> {
        if self.resampler.is_none() {
            return Ok(Vec::new());
        }
        let remaining = self.expected().saturating_sub(self.output_frames) as usize;
        let mut out = Vec::new();
        while out.len() / self.channels < remaining {
            out.extend(self.block()?);
        }
        out.truncate(remaining * self.channels);
        Ok(out)
    }
}
struct Segment {
    index: usize,
    start: u64,
    end: Option<u64>,
    offset: u64,
}

pub struct Sequence {
    openers: Vec<DecoderFactory>,
    decoder: Option<StreamDecoder>,
    converter: Converter,
    pub formats: Vec<Option<TrackFormat>>,
    index: usize,
    segments: VecDeque<Segment>,
    cursor: u64,
    channels: usize,
    rate: u32,
    done: bool,
    packet: Vec<f32>,
    packet_offset: usize,
}
impl Sequence {
    pub fn new(
        paths: Vec<PathBuf>,
        rate: u32,
        channels: usize,
        start: usize,
        seconds: f64,
    ) -> Result<Self> {
        let openers = paths
            .into_iter()
            .map(|path| Arc::new(move || StreamDecoder::open(&path)) as DecoderFactory)
            .collect();
        Self::from_openers(openers, rate, channels, start, seconds)
    }
    pub fn from_openers(
        openers: Vec<DecoderFactory>,
        rate: u32,
        channels: usize,
        start: usize,
        seconds: f64,
    ) -> Result<Self> {
        anyhow::ensure!(
            channels > 0 && channels <= MAX_CHANNELS && rate > 0,
            "无效的输出格式"
        );
        anyhow::ensure!(start < openers.len(), "播放队列为空");
        let mut decoder = openers[start]()?;
        if seconds > 0.0 {
            decoder.seek(seconds)?;
        }
        let converter = Converter::new(decoder.format.sample_rate, rate, channels)?;
        let mut formats = vec![None; openers.len()];
        formats[start] = Some(decoder.format.clone());
        Ok(Self {
            openers,
            decoder: Some(decoder),
            converter,
            formats,
            index: start,
            segments: VecDeque::from([Segment {
                index: start,
                start: 0,
                end: None,
                offset: (seconds * rate as f64).round() as u64,
            }]),
            cursor: 0,
            channels,
            rate,
            done: false,
            packet: Vec::new(),
            packet_offset: 0,
        })
    }
    fn wrap(&mut self, pcm: Vec<f32>) -> Vec<PcmFrame> {
        let mut out = Vec::with_capacity(pcm.len() / self.channels);
        for data in pcm.chunks_exact(self.channels) {
            while self.segments.len() > 1
                && self
                    .segments
                    .front()
                    .unwrap()
                    .end
                    .is_some_and(|end| self.cursor >= end)
            {
                self.segments.pop_front();
            }
            let segment = self.segments.front().unwrap();
            let mut samples = [0.0; MAX_CHANNELS];
            samples[..self.channels].copy_from_slice(data);
            out.push(PcmFrame {
                samples,
                track: segment.index,
                position: segment.offset + self.cursor - segment.start,
            });
            self.cursor += 1;
        }
        out
    }
    pub fn next_block(&mut self) -> Result<Option<Vec<PcmFrame>>> {
        if self.done {
            return Ok(None);
        }
        loop {
            if self.packet_offset == self.packet.len() {
                self.packet = match self.decoder.as_mut().unwrap().next_packet()? {
                    Some(packet) => packet,
                    None => Vec::new(),
                };
                self.packet_offset = 0;
            }
            if self.packet_offset < self.packet.len() {
                let in_channels = self.decoder.as_ref().unwrap().format.channels;
                let end = (self.packet_offset + 4096 * in_channels).min(self.packet.len());
                let pcm = &self.packet[self.packet_offset..end];
                self.packet_offset = end;
                anyhow::ensure!(pcm.iter().all(|v| v.is_finite()), "音频包含无效采样值");
                let in_channels = self.decoder.as_ref().unwrap().format.channels;
                let mut mapped = Vec::with_capacity(pcm.len() / in_channels * self.channels);
                for frame in pcm.chunks_exact(in_channels) {
                    for c in 0..self.channels {
                        mapped.push(if self.channels == 1 {
                            frame.iter().sum::<f32>() / in_channels as f32
                        } else {
                            frame[c.min(in_channels - 1)]
                        });
                    }
                }
                let out = self.converter.push(&mapped)?;
                if !out.is_empty() {
                    return Ok(Some(self.wrap(out)));
                }
                continue;
            }
            let end = self.converter.expected();
            self.segments.back_mut().unwrap().end = Some(end);
            if self.index + 1 == self.openers.len() {
                let out = self.converter.finish()?;
                self.done = true;
                return if out.is_empty() {
                    Ok(None)
                } else {
                    Ok(Some(self.wrap(out)))
                };
            }
            let next = self.openers[self.index + 1]()?;
            self.index += 1;
            self.formats[self.index] = Some(next.format.clone());
            if next.format.sample_rate == self.converter.input_rate {
                self.segments.push_back(Segment {
                    index: self.index,
                    start: end,
                    end: None,
                    offset: 0,
                });
                self.decoder = Some(next);
            } else {
                let tail = self.converter.finish()?;
                let out = self.wrap(tail);
                self.converter = Converter::new(next.format.sample_rate, self.rate, self.channels)?;
                self.cursor = 0;
                self.segments = VecDeque::from([Segment {
                    index: self.index,
                    start: 0,
                    end: None,
                    offset: 0,
                }]);
                self.decoder = Some(next);
                if !out.is_empty() {
                    return Ok(Some(out));
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_audio;
    fn render(paths: Vec<PathBuf>, rate: u32) -> Vec<PcmFrame> {
        let mut sequence = Sequence::new(paths, rate, 2, 0, 0.0).unwrap();
        let mut frames = Vec::new();
        while let Some(block) = sequence.next_block().unwrap() {
            frames.extend(block);
        }
        frames
    }
    #[test]
    fn split_wav_is_sample_exact_and_has_no_inserted_silence() {
        let dir = test_audio::directory();
        let pcm: Vec<i16> = (0..48000)
            .flat_map(|i| {
                let v = ((i as f64 * 0.031).sin() * 12000.0) as i16;
                [v, -v]
            })
            .collect();
        let a = dir.join("a.wav");
        let b = dir.join("b.wav");
        let full = dir.join("full.wav");
        let split = 21370;
        test_audio::wav(&a, 48000, 2, &pcm[..split]);
        test_audio::wav(&b, 48000, 2, &pcm[split..]);
        test_audio::wav(&full, 48000, 2, &pcm);
        for rate in [48000, 44100, 96000] {
            let split_pcm = render(vec![a.clone(), b.clone()], rate);
            let continuous = render(vec![full.clone()], rate);
            assert_eq!(split_pcm.len(), continuous.len());
            for (x, y) in split_pcm.iter().zip(&continuous) {
                for ch in 0..2 {
                    assert!(
                        (x.samples[ch] - y.samples[ch]).abs() < 1e-6,
                        "boundary mismatch at output rate {rate}"
                    );
                }
            }
            let expected = (split as f64 / 2.0 * rate as f64 / 48000.0).round() as usize;
            assert_eq!(split_pcm.iter().position(|f| f.track == 1), Some(expected));
            assert_eq!(split_pcm[expected].position, 0);
        }
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn two_hour_file_starts_with_bounded_blocks_and_seeks_to_end() {
        let dir = test_audio::directory();
        let path = dir.join("two-hours.wav");
        test_audio::sparse(&path, 96000, 2, 7200);
        let start = std::time::Instant::now();
        let mut sequence = Sequence::new(vec![path.clone()], 48000, 2, 0, 0.0).unwrap();
        let first = sequence.next_block().unwrap().unwrap();
        assert!(first.len() < 8192);
        assert!(start.elapsed().as_secs_f64() < 2.0);
        let mut end = Sequence::new(vec![path], 48000, 2, 0, 7199.75).unwrap();
        let mut count = 0;
        while let Some(block) = end.next_block().unwrap() {
            assert!(block.len() < 8192);
            count += block.len();
        }
        assert_eq!(count, 12000);
        assert_eq!(first[0].position, 0);
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn format_change_has_correct_counts_and_channel_mapping() {
        let dir = test_audio::directory();
        let a = dir.join("mono.wav");
        let b = dir.join("stereo.wav");
        test_audio::wav(&a, 44100, 1, &vec![8192; 4410]);
        test_audio::wav(&b, 48000, 2, &vec![-8192; 9600]);
        let out = render(vec![a, b], 48000);
        assert_eq!(out.len(), 9600);
        assert_eq!(out.iter().filter(|f| f.track == 1).count(), 4800);
        assert!(out[200].samples[0] > 0.2);
        assert_eq!(out[200].samples[0], out[200].samples[1]);
        assert!(out[7000].samples[0] < -0.2);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
