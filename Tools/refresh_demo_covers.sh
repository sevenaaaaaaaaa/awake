#!/bin/bash
# Awake 演示曲库 · 只换封面, 不碰音频
#
# 用法:  bash Tools/refresh_demo_covers.sh [--dry-run]
#
# 做的事:
#   1. 对 DemoMusic 下每个专辑目录, 用 Tools/make_spectrum_covers.py 渲染真实频谱封面
#   2. 用 metaflac 只摘掉 PICTURE 块再导入新图 —— 音频帧一个字节都不动
#   3. 逐文件核验: STREAMINFO 里的 MD5 必须不变, 标签必须不变, 只多一张图
#
# 音频不动是靠 metaflac 保证的 (它只重写 metadata block), 不是靠 ffmpeg 重新封装.
set -euo pipefail
cd "$(dirname "$0")/.."

PY="${AWAKE_PY:-}"
if [ -z "$PY" ]; then
  for c in python3 /Users/sevenaaaaaaa/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/bin/python3; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import numpy, PIL' >/dev/null 2>&1; then PY="$c"; break; fi
  done
fi
[ -n "$PY" ] || { echo "需要带 numpy + Pillow 的 python3" >&2; exit 1; }

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

OUT="$PWD/.build/cover-work/covers"
mkdir -p "$OUT"

declare -i changed=0 failed=0
for album in DemoMusic/*/; do
  album="${album%/}"
  slug="$(basename "$album")"
  files=()
  while IFS= read -r f; do files+=("$f"); done < <(find "$album" -name '*.flac' | sort)
  if [ "${#files[@]}" -ne 3 ]; then echo "跳过 $slug: 曲目数 ${#files[@]} != 3" >&2; continue; fi

  cover="$OUT/$slug.png"
  "$PY" Tools/make_spectrum_covers.py "$cover" "${files[@]}" || { echo "渲染失败: $slug" >&2; failed+=1; continue; }

  for f in "${files[@]}"; do
    before_md5=$(metaflac --show-md5sum "$f")
    before_tags=$(metaflac --export-tags-to=- "$f" | sort)
    before_size=$(wc -c < "$f")
    if [ "$DRY" = "0" ]; then
      metaflac --remove --block-type=PICTURE --dont-use-padding "$f"
      metaflac --import-picture-from="3|image/png||800x800x24|$cover" "$f"
    fi
    after_md5=$(metaflac --show-md5sum "$f")
    after_tags=$(metaflac --export-tags-to=- "$f" | sort)
    after_size=$(wc -c < "$f")
    pic=$(metaflac --list "$f" | grep -c 'type: 6 (PICTURE)' || true)
    mime=$(metaflac --list "$f" | grep 'MIME type' | head -1 | sed 's/.*: //')
    ok="_ok"
    [ "$before_md5" = "$after_md5" ] || ok="_AUDIO_CHANGED"
    [ "$before_tags" = "$after_tags" ] || ok="${ok}_TAGS_CHANGED"
    [ "$pic" -eq 1 ] || ok="${ok}_PIC_COUNT_$pic"
    printf '%-42s %9s -> %9s  %-13s %s\n' "$(basename "$f")" "$before_size" "$after_size" "$mime" "$ok"
    if [ "$ok" = "_ok" ]; then changed+=1; else failed+=1; fi
  done
done

echo "-----"
echo "成功 $changed 个文件, 失败 $failed 个"
[ "$failed" -eq 0 ]