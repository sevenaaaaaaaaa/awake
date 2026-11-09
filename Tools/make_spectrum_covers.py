#!/usr/bin/env python3
"""Awake 演示曲库 · 真实频谱封面生成器 v3

用法:
  python3 Tools/make_spectrum_covers.py OUT.png [--lo DB] [--hi DB] TRACK1.flac TRACK2.flac ...

这张图里没有一处装饰: 每个像素都是曲目本身的能量.

  时间轴  三首曲目按时长首尾相接, 从左到右; 每首占宽 ∝ 其真实时长
  频率轴  对数 20 Hz .. 20 kHz, 低在下; 每十倍频程等高 (听感轴)
  亮度    绝对 dBFS 固定窗口, 全曲库同一窗口 -> 三张封面可比, 不靠"每张自动拉满"
  颜色    暖石墨 #121110 -> 琥珀 #d9a24a, 与界面同一套色阶
  分析    96 kHz 单声道(左右平均), Hann 65536 点 (0.68 s) -> 低频不出"药丸"
"""
import argparse
import subprocess

import numpy as np
from PIL import Image

SR = 96000
NFFT = 65536          # 0.68 s 分析窗: 60 Hz 的正弦画出来是线, 不是块
WIDTH = 800
HEIGHT = 800
F_LO, F_HI = 20.0, 20000.0

RAMP_T = np.array([0.00, 0.18, 0.42, 0.66, 0.84, 1.00])
RAMP_R = np.array([18.0, 21.0, 40.0, 105.0, 186.0, 232.0])
RAMP_G = np.array([17.0, 19.0, 35.0, 82.0, 145.0, 188.0])
RAMP_B = np.array([15.0, 16.0, 28.0, 56.0, 82.0, 104.0])


def decode_mono(path):
    out = subprocess.run(
        ["ffmpeg", "-v", "error", "-nostdin", "-i", path,
         "-ac", "1", "-ar", str(SR), "-f", "f32le", "-"],
        check=True, stdout=subprocess.PIPE).stdout
    return np.frombuffer(out, dtype="<f4").astype(np.float64)


def render(paths, out_path, lo, hi, line_width=16):
    audio = [decode_mono(p) for p in paths]
    lens = np.array([len(a) for a in audio], dtype=float)
    cols_per = np.floor(lens / lens.sum() * WIDTH).astype(int)
    cols_per[-1] = WIDTH - cols_per[:-1].sum()

    freqs = np.fft.rfftfreq(NFFT, d=1.0 / SR)
    # 每一行图像 = 一个对数频带; 取该带内的峰值, 而不是点采样.
    # 点采样会让高频细线落在两行之间而变暗 (8 kHz 那条会几乎看不见);
    # 取带内峰值, 任何频率上的线都是同一个亮度, 而且每个像素仍然是真实能量.
    edges = np.logspace(np.log10(F_LO), np.log10(F_HI), HEIGHT + 1)
    band_lo = np.searchsorted(freqs, edges[:-1])
    win = np.hanning(NFFT)
    win = win / win.sum() * 2.0        # 纯音 -> 峰值 = 时域振幅

    grid = np.empty((HEIGHT, WIDTH), dtype=np.float32)
    col = 0
    for sig, n in zip(audio, cols_per):
        if len(sig) < NFFT:
            sig = np.pad(sig, (0, NFFT - len(sig)))
        hop = max(1, (len(sig) - NFFT) // max(1, n - 1))
        for j in range(n):
            i = min(j * hop, len(sig) - NFFT)
            mag = np.abs(np.fft.rfft(sig[i:i + NFFT] * win))
            band = np.maximum.reduceat(mag, band_lo)      # 低 -> 高
            grid[:, col] = band[::-1]                     # 翻成上高下低
            col += 1

    db = 20.0 * np.log10(np.maximum(grid, 1e-12))
    del grid
    peak_db = round(float(db.max()), 1)
    u = np.clip((db - lo) / (hi - lo), 0.0, 1.0)
    del db
    # 线宽下限: 这张图在界面里最大只显示到 200 px 上下 (专辑卡片 170 / 详情 168 / 播放条 56),
    # 缩下去以后 1 px 的线只剩 0.2 px, 会被平均成"一片更黑的背景". 所以线必须画粗.
    r = max(0, (line_width - 1) // 2)
    if r > 0:
        stack = [u]
        for d in range(1, r + 1):
            stack.append(np.vstack([u[d:], u[-d:]]))
            stack.append(np.vstack([u[:d], u[:-d]]))
        u = np.maximum.reduce(stack)

    img = np.stack([np.interp(u, RAMP_T, RAMP_R),
                    np.interp(u, RAMP_T, RAMP_G),
                    np.interp(u, RAMP_T, RAMP_B)], axis=-1).astype(np.uint8)
    Image.fromarray(img, "RGB").save(out_path)
    return {"cols": cols_per.tolist(), "peak_db": peak_db}


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("tracks", nargs="+")
    ap.add_argument("--lo", type=float, default=-64.0)
    ap.add_argument("--hi", type=float, default=-16.0)
    ap.add_argument("--line-width", type=int, default=16, help="线宽下限(800 px 坐标系)")
    a = ap.parse_args()
    info = render(a.tracks, a.out, a.lo, a.hi, a.line_width)
    print(f"{a.out}  列/曲={info['cols']}  峰值={info['peak_db']} dBFS  窗口={a.lo}..{a.hi}")