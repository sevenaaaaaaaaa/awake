#!/bin/bash
# make_demo_music.sh — 生成 Awake 演示曲库（3 张专辑 × 3 首，24-bit / 96 kHz FLAC）
#
# 设计目标：不用任何版权音频，全部由 ffmpeg lavfi 合成；
# 每首的频谱重心刻意拉开（低频 / 中频 / 高频 / 白噪 / 和弦 / 扫频 / 拍频），
# 用来演示 Awake 的 AutoEQ 自动补偿。每张专辑带 800x800 渐变封面与同名 LRC。
#
# 可重复执行：先写入 .build 下的暂存目录，全部成功后才替换 DemoMusic/，
# 中途失败不会破坏上一次的成品。
#
# 用法: bash Tools/make_demo_music.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
DEMO_DIR="$ROOT/DemoMusic"
STAGE="$ROOT/.build/demo-music-stage"
ART="$ROOT/.build/demo-music-artwork"
ARTIST="Awake Lab"
TOTAL_TRACKS=9
START_SECONDS=$SECONDS

log()  { printf '==> %s\n' "$*"; }
warn() { printf '==> WARN: %s\n' "$*" >&2; }
die()  { printf '==> ERROR: %s\n' "$*" >&2; exit 1; }

command -v ffmpeg  >/dev/null 2>&1 || die "未找到 ffmpeg（brew install ffmpeg）"
command -v ffprobe >/dev/null 2>&1 || die "未找到 ffprobe（brew install ffmpeg）"
command -v magick  >/dev/null 2>&1 || warn "未找到 ImageMagick(magick)，封面将退化为纯渐变（无文字）"

# ---- 字体（中文标题需要 CJK 字体） -----------------------------------------
FONT_CJK=""
for f in "/System/Library/Fonts/STHeiti Medium.ttc" \
         "/System/Library/Fonts/PingFang.ttc" \
         "/System/Library/Fonts/Hiragino Sans GB.ttc"; do
  if [ -f "$f" ]; then FONT_CJK="$f"; break; fi
done
FONT_LATIN=""
for f in "/System/Library/Fonts/HelveticaNeue.ttc" \
         "/System/Library/Fonts/Helvetica.ttc" \
         "/System/Library/Fonts/Supplemental/Arial.ttf"; do
  if [ -f "$f" ]; then FONT_LATIN="$f"; break; fi
done
[ -n "$FONT_CJK" ] || warn "未找到中文字体，封面标题会退化为英文占位"

# ---- 专辑元数据 -------------------------------------------------------------
album_title=("夜航" "白噪实验室" "频谱边界")
album_dir=("01 夜航" "02 白噪实验室" "03 频谱边界")
album_genre=("Ambient" "Experimental" "Electronic")
album_accent=("143,168,255" "155,231,216" "255,176,122")
grad_c0=("0x05060F" "0x080C0D" "0x120611")
grad_c1=("0x3B2A8C" "0x274A45" "0x6B1E5A")
grad_c2=("0x1A1040" "0x0E1A22" "0x2A0E2E")
album_year=(2026 2026 2026)

# ---- LRC 歌词（中英各三首；纯器乐演示，歌词只用于展示同步滚动） -------------
lrc_lines() {
  case "$1" in
    low)     printf '%s\n' "六十赫兹的深海" "低音在胸腔里起伏" "夜色有了重量" ;;
    mid)     printf '%s\n' "一千赫兹的指针" "停在人声的正中" "你说的话有了轮廓" ;;
    high)    printf '%s\n' "八千赫兹的星尘" "在耳廓边缘发亮" "天亮之前不会落下" ;;
    white)   printf '%s\n' "Static fills the empty room" "Every frequency at once" "Nothing and everything" ;;
    pink)    printf '%s\n' "Pink tides under the floor" "Soft rain on a sleeping city" "Drift, drift, drift" ;;
    chord)   printf '%s\n' "Three notes hold the sky" "A major, open and warm" "The room begins to sing" ;;
    sweep)   printf '%s\n' "从四十赫兹出发" "一路向上" "直到空气变薄" ;;
    beat)    printf '%s\n' "八十与八十四" "每秒四次相遇" "心跳被轻轻推动" ;;
    square)  printf '%s\n' "奇次谐波堆叠" "像霓虹在闪" "边缘锋利而明亮" ;;
    *) return 0 ;;
  esac
}

write_lrc() {
  local path="$1" ti="$2" ar="$3" al="$4" key="$5" dur="$6"
  {
    printf '[ti:%s]\n[ar:%s]\n[al:%s]\n[by:Awake Demo Library]\n[ve:0.1]\n\n' "$ti" "$ar" "$al"
    local i=0 line ts
    while IFS= read -r line; do
      ts=$(awk -v d="$dur" -v i="$i" 'BEGIN { t=d*(0.15+0.24*i); printf "%02d:%05.2f", int(t/60), t-int(t/60)*60 }')
      printf '[%s]%s\n' "$ts" "$line"
      i=$((i+1))
    done < <(lrc_lines "$key")
  } > "$path"
}

# ---- 封面：ffmpeg 渐变（+ 暗角 + 颗粒），文字由 ImageMagick 栅格化后 overlay --
make_cover() {
  local i="$1"
  local out="$ART/cover-$((i+1)).jpg"
  local layer="$ART/cover-$((i+1))-text.png"
  local grad="gradients=s=800x800:c0=${grad_c0[$i]}:c1=${grad_c1[$i]}:c2=${grad_c2[$i]}:n=3:x0=120:y0=40:x1=700:y1=800"

  if command -v magick >/dev/null 2>&1 && [ -n "$FONT_CJK" ]; then
    magick -size 800x800 xc:none \
      -font "$FONT_LATIN" -fill 'rgba(255,255,255,0.55)' -pointsize 20 -gravity northwest \
      -annotate +72+74 "AWAKE DEMO  ·  0$((i+1))" \
      -fill "rgba(${album_accent[$i]},0.65)" -draw "rectangle 72,536 312,538" \
      -font "$FONT_CJK" -fill 'rgba(255,255,255,0.95)' -pointsize 84 -gravity northwest \
      -annotate +70+574 "${album_title[$i]}" \
      -font "$FONT_LATIN" -fill 'rgba(255,255,255,0.62)' -pointsize 22 -gravity northwest \
      -annotate +74+700 "$ARTIST  ·  ${album_genre[$i]}" \
      -fill 'rgba(255,255,255,0.42)' -pointsize 18 -gravity southeast \
      -annotate +72+70 "24BIT / 96KHZ  ·  3 TRACKS" \
      "$layer"
    ffmpeg -hide_banner -loglevel error -y \
      -nostdin -f lavfi -i "$grad" -i "$layer" \
      -filter_complex "[0:v]vignette=PI/4,noise=alls=5:allf=t[bg];[bg][1:v]overlay=0:0:format=auto,format=rgb24" \
      -frames:v 1 -q:v 3 "$out"
  else
    ffmpeg -hide_banner -loglevel error -y -nostdin -f lavfi -i "$grad" \
      -vf "vignette=PI/4,noise=alls=5:allf=t,format=rgb24" \
      -frames:v 1 -q:v 3 "$out"
  fi

  [ -s "$out" ] || die "封面生成失败: $out"
  printf '%s' "$out"
}

# ---- 清洗暂存目录 -----------------------------------------------------------
log "准备暂存目录（可重复执行，成功后原子替换 DemoMusic/）"
rm -rf "$STAGE" "$ART"
mkdir -p "$STAGE" "$ART"

# ---- 逐张专辑生成 -----------------------------------------------------------
log "生成 3 张专辑封面（800x800 JPG）"
covers=()
for i in 0 1 2; do
  covers[$i]=$(make_cover "$i")
  log "封面 0$((i+1)) ${album_title[$i]}: $(basename "${covers[$i]}") ($(wc -c < "${covers[$i]}" | tr -d ' ') bytes)"
done

# 专辑索引 | 曲号 | 标题 | lavfi 源 | 时长(s) | LRC key
TRACKS=$(cat <<'TABLE'
0|1|低频原点|sine=frequency=60:sample_rate=96000:duration=32|32|low
0|2|中频指针|sine=frequency=1000:sample_rate=96000:duration=28|28|mid
0|3|高频星尘|sine=frequency=8000:sample_rate=96000:duration=26|26|high
1|1|白噪底噪|anoisesrc=color=white:sample_rate=96000:duration=30:amplitude=0.28|30|white
1|2|粉噪潮汐|anoisesrc=color=pink:sample_rate=96000:duration=34:amplitude=0.42|34|pink
1|3|和弦共鸣|aevalsrc=exprs=0.20*(sin(2*PI*220*t)+sin(2*PI*277.18*t)+sin(2*PI*329.63*t)+0.5*sin(2*PI*110*t)):s=96000:d=36|36|chord
2|1|全频扫掠|aevalsrc=exprs=0.35*sin(2*PI*(40*t+(16000-40)*t*t/(2*30))):s=96000:d=30|30|sweep
2|2|低频拍频|aevalsrc=exprs=0.35*(sin(2*PI*80*t)+sin(2*PI*84*t)):s=96000:d=28|28|beat
2|3|方波泛音|aevalsrc=exprs=0.18*(sin(2*PI*100*t)+sin(2*PI*300*t)+sin(2*PI*500*t)+sin(2*PI*700*t)):s=96000:d=34|34|square
TABLE
)

manifest=""
while IFS='|' read -r ai no title src dur lkey; do
  [ -n "$ai" ] || continue
  case "$ai" in \#*) continue ;; esac
  if [ "$dur" -lt 25 ] || [ "$dur" -gt 40 ]; then
    die "曲目时长 $dur 秒超出 25-40 秒范围: $title"
  fi
  adir="${album_dir[$ai]}"
  mkdir -p "$STAGE/$adir"
  num=$(printf '%02d' "$no")
  base="$STAGE/$adir/$num - $title"
  cover="${covers[$ai]}"
  fade_out=$((dur - 2))
  log "合成 $adir/$num $title  [${src%%:*} · $dur s]"

  ffmpeg -hide_banner -loglevel error -y -nostdin \
    -f lavfi -i "$src" -i "$cover" \
    -map 0:a:0 -map 1:v:0 \
    -af "afade=t=in:st=0:d=2,afade=t=out:st=$fade_out:d=2" \
    -ac 2 -ar 96000 \
    -c:a flac -sample_fmt s32 -bits_per_raw_sample 24 -compression_level 8 \
    -c:v copy -disposition:v attached_pic \
    -metadata title="$title" \
    -metadata artist="$ARTIST" \
    -metadata album="${album_title[$ai]}" \
    -metadata album_artist="$ARTIST" \
    -metadata date="${album_year[$ai]}" \
    -metadata tracknumber="$no/3" \
    -metadata genre="${album_genre[$ai]}" \
    -metadata comment="Awake demo library · synthesized with ffmpeg lavfi · 24-bit/96kHz" \
    "$base.flac"

  write_lrc "$base.lrc" "$title" "$ARTIST" "${album_title[$ai]}" "$lkey" "$dur"
  [ -s "$base.flac" ] || die "FLAC 生成失败: $base.flac"
  manifest="$manifest$adir|$num|$title|$dur\n"
done <<< "$TRACKS"

# ---- 曲库说明 ---------------------------------------------------------------
cat > "$STAGE/README.md" <<'README'
# Awake 演示曲库

全部音频由 Tools/make_demo_music.sh 用 ffmpeg lavfi 实时合成，无任何版权素材。

- 格式：FLAC · 24-bit / 96 kHz · 立体声
- 结构：3 张专辑 × 3 首，每首 25–40 秒
- 标签：title / artist / album / album_artist / date / tracknumber / genre
- 封面：800×800 JPG，以 attached_pic 内嵌
- 歌词：与音频同名的 .lrc（第 1 张中文，第 2 张英文，第 3 张中文）

## 频谱设计（用于演示 AutoEQ）

| 专辑 | 曲目 | 主频特征 |
| --- | --- | --- |
| 夜航 | 低频原点 | 60 Hz 纯正弦，低频重心 |
| 夜航 | 中频指针 | 1 kHz 纯正弦，人声频段 |
| 夜航 | 高频星尘 | 8 kHz 纯正弦，高频重心 |
| 白噪实验室 | 白噪底噪 | 全频白噪 |
| 白噪实验室 | 粉噪潮汐 | 粉噪（-3 dB/oct） |
| 白噪实验室 | 和弦共鸣 | A 大三和弦（220/277.18/329.63 Hz + 110 Hz） |
| 频谱边界 | 全频扫掠 | 40 Hz → 16 kHz 线性扫频 |
| 频谱边界 | 低频拍频 | 80 Hz + 84 Hz，4 Hz 拍频 |
| 频谱边界 | 方波泛音 | 100 Hz 奇次谐波（300/500/700 Hz） |

重新生成：bash Tools/make_demo_music.sh
README
printf '%b' "$manifest" > "$STAGE/.manifest"

# ---- 校验 -------------------------------------------------------------------
log "校验：数量 / 位深 / 采样率 / 封面 / 标签"
flac_count=$(find "$STAGE" -name '*.flac' -type f | wc -l | tr -d ' ')
[ "$flac_count" -eq "$TOTAL_TRACKS" ] || die "FLAC 数量应为 ${TOTAL_TRACKS}，实际 $flac_count"
lrc_count=$(find "$STAGE" -name '*.lrc' -type f | wc -l | tr -d ' ')
[ "$lrc_count" -eq "$TOTAL_TRACKS" ] || die "LRC 数量应为 ${TOTAL_TRACKS}，实际 $lrc_count"

while IFS='|' read -r ai no title src dur lkey; do
  [ -n "$ai" ] || continue
  case "$ai" in \#*) continue ;; esac
  f="$STAGE/${album_dir[$ai]}/$(printf '%02d' "$no") - $title.flac"
  audio=$(ffprobe -v error -select_streams a:0 \
    -show_entries stream=codec_name,sample_rate,bits_per_raw_sample,channels -of default=nw=1 "$f")
  echo "$audio" | grep -q 'codec_name=flac'            || die "编码不是 FLAC: $f"
  echo "$audio" | grep -q 'sample_rate=96000'          || die "采样率不是 96k: $f"
  echo "$audio" | grep -q 'bits_per_raw_sample=24'     || die "位深不是 24-bit: $f"
  echo "$audio" | grep -q 'channels=2'                 || die "不是立体声: $f"
  pic=$(ffprobe -v error -select_streams v:0 -show_entries stream_disposition=attached_pic -of csv=p=0 "$f")
  [ "$pic" = "1" ] || die "缺少内嵌封面: $f"
  tags=$(ffprobe -v error -show_entries format_tags=title,artist,album,album_artist,date,track,genre -of default=nw=1 "$f")
  for key in title artist album album_artist date track genre; do
    echo "$tags" | grep -q "^TAG:$key=" || die "缺少标签 $key: $f"
  done
done <<< "$TRACKS"

# ---- 原子替换 ---------------------------------------------------------------
rm -rf "$DEMO_DIR"
mv "$STAGE" "$DEMO_DIR"

TOTAL_BYTES=$(du -sk "$DEMO_DIR" | awk '{print $1}')
FLAC_BYTES=$(find "$DEMO_DIR" -name '*.flac' -exec stat -f '%z' {} + | awk '{s+=$1} END {print s}')
log "完成：$flac_count 首 FLAC / $lrc_count 个 LRC / 3 张封面"
log "目录：${DEMO_DIR#$ROOT/}  ·  总大小 $((TOTAL_BYTES / 1024)) MB（FLAC $((FLAC_BYTES / 1024 / 1024)) MB）"
log "耗时：$((SECONDS - START_SECONDS)) 秒"
if [ $((SECONDS - START_SECONDS)) -gt 180 ]; then
  warn "生成耗时超过 3 分钟目标"
fi
find "$DEMO_DIR" -name '*.flac' -type f | sort | sed "s|^$ROOT/|    |"
