#!/usr/bin/env python3
"""合成一份 MusicBeeLibrary.mbl 样本，用来验证 `awake-cli mbl` 的解析与码表命令。

**这不是真实 MusicBee 输出**——它是按 `musicbee.rs` 里那份格式写的假数据。
用途只有两个：
1. 让 `mbl inspect` / `mbl tags` / `mbl apply` 有一条不依赖用户 Windows 机器的重跑路径；
2. 在 CI 环境里造"跨两个盘 + 带常见标签码"的最小用例。

真实码表的最终判定仍然要靠用户的真实 .mbl：本脚本只证明"命令能跑、字段能读出来"，
不证明"65 就是 TrackTitle"——后者由 SDK 枚举（B 级）与真实文件样例共同判定。

用法:
    python3 Tools/make_sample_mbl.py                # 写到系统临时目录，路径打印在输出里
    cargo run -p awake-cli -- mbl tags <上一步打印的路径>
"""

import os
import struct
import tempfile

EPOCH = 621_355_968_000_000_000  # .NET 0001-01-01 到 Unix 纪元的 ticks


def ticks(ms: int) -> bytes:
    raw = ms * 10_000 + EPOCH
    # 真实文件里最高字节恒为 0x08；低 7 字节才是数值。
    return ((raw & 0x00FF_FFFF_FFFF_FFFF) | 0x0800_0000_0000_0000).to_bytes(8, "little")


def leb(value: int) -> bytes:
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def string(text: str) -> bytes:
    data = text.encode("utf-8")
    return leb(len(data)) + data


def record(path, play, last, added, tags, designation=2):
    out = bytearray()
    out += struct.pack("<B", designation)
    out += struct.pack("<B", 0)  # status
    out += struct.pack("<B", 0)  # unknown
    out += struct.pack("<H", play)
    out += ticks(last) if last else b"\x00" * 8
    out += struct.pack("<H", 0)  # skips
    out += string(path)
    out += struct.pack("<i", 12345678)  # size
    out += struct.pack("<i", 44100)
    out += struct.pack("<B", 2)  # channel mode stereo
    out += struct.pack("<B", 0)  # bitrate type
    out += struct.pack("<h", 1000)  # kbps
    out += struct.pack("<i", 245)  # seconds
    out += ticks(added)
    out += ticks(added + 1000)
    out += struct.pack("<B", 254)  # 封面段结束（>253）
    out += struct.pack("<B", 0)  # tags_type
    for code, value in tags:
        out += struct.pack("<B", code)
        out += string(value)
    out += struct.pack("<B", 0)  # tags 结束
    return bytes(out)


def main():
    rows = [
        # F: 盘
        (r"F:\Music\Beethoven\Symphony No. 5\01.flac", 12, 1_760_000_000_000,
         [(65, "Symphony No. 5 in C minor, Op. 67 - I. Allegro con brio"),
          (30, "Symphony No. 5"), (32, "Wiener Philharmoniker"),
          (31, "Wiener Philharmoniker"), (88, "1995"), (86, "1"), (59, "Classical")]),
        (r"F:\Music\Beethoven\Symphony No. 5\02.flac", 3, 1_750_000_000_000,
         [(65, "Symphony No. 5 in C minor, Op. 67 - II. Andante con moto"),
          (30, "Symphony No. 5"), (32, "Wiener Philharmoniker"), (88, "1995"), (86, "2")]),
        (r"F:\Music\Miles Davis\Kind of Blue\01.flac", 0, None,
         [(65, "So What"), (30, "Kind of Blue"), (32, "Miles Davis"), (88, "1959"), (86, "1")]),
        # G: 盘 —— 跨盘的证据
        (r"G:\Archive\Bach\Goldberg Variations\01.flac", 41, 1_700_000_000_000,
         [(65, "Goldberg Variations, BWV 988 - Aria"), (30, "Goldberg Variations"),
          (32, "Glenn Gould"), (88, "1981"), (86, "1")]),
        # 一个表外的码：让 `mbl tags` 的 unknown 分支有东西可报
        (r"G:\Archive\Unknown\x.flac", 0, None,
         [(65, "Mystery Track"), (200, "自定义标签的值")]),
    ]
    body = bytearray()
    for path, play, last, tags in rows:
        body += record(path, play, last, 1_700_000_000_000, tags)
    body += struct.pack("<B", 1)  # 结束
    head = struct.pack("<I", (len(rows) << 8) | 8)
    # 输出走系统安全临时文件 API：不可预测文件名、原子创建，杜绝 argv 指定任意路径；
    # 实际路径打印在输出里，复制给 mbl inspect / mbl tags 即可。
    fd, out_path = tempfile.mkstemp(prefix="sample_", suffix=".mbl")
    with os.fdopen(fd, "wb") as handle:
        handle.write(head + body)
    print(f"wrote {out_path} ({len(head + body)} bytes, {len(rows)} records)")


if __name__ == "__main__":
    main()
