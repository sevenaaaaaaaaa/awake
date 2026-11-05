#!/bin/bash
# build_awake.sh — 构建并打包 dist/Awake.app
#
# 用法:
#   ./build_awake.sh            # release（默认）
#   ./build_awake.sh debug      # debug
#
# 产物: dist/Awake.app
# 说明: 与 build_app.sh 共用 TMPDIR / 模块缓存设置；会把 SwiftPM 资源 bundle、
#       应用图标与演示曲库一起打进 .app，双击即可听到声音。
set -euo pipefail
cd "$(dirname "$0")"

export TMPDIR="$PWD/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/clang-module-cache"
mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"

CONFIG="${1:-release}"
case "$CONFIG" in
  release|debug) ;;
  *)
    echo "用法: ./build_awake.sh [release|debug]" >&2
    exit 2
    ;;
esac

APP="dist/Awake.app"
BIN=".build/$CONFIG/Awake"

echo "==> swift build -c $CONFIG --product Awake"
swift build -c "$CONFIG" --product Awake --disable-sandbox \
  --cache-path .build/spm-cache --scratch-path .build

if [ ! -x "$BIN" ]; then
  echo "==> ERROR: 构建产物缺失: $BIN" >&2
  exit 1
fi

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Awake"
cp Resources/AwakeInfo.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -f Resources/Awake.icns ]; then
  cp Resources/Awake.icns "$APP/Contents/Resources/Awake.icns"
else
  echo "==> WARN: 缺少 Resources/Awake.icns；先运行 swift Tools/make_awake_icon.swift" >&2
fi

# SwiftPM 资源 bundle（AwakeCore）随 app 一起分发，Bundle.module 才能在 .app 内找到资源
shopt -s nullglob
for bundle in ".build/$CONFIG"/*.bundle; do
  cp -R "$bundle" "$APP/Contents/Resources/"
  echo "==> 打包资源: $(basename "$bundle")"
done
shopt -u nullglob

# 演示曲库（9 首 24/96 FLAC）打进 Resources，双击 app 也能直接试听
if [ -d DemoMusic ]; then
  cp -R DemoMusic "$APP/Contents/Resources/DemoMusic"
  echo "==> 打包演示曲库: $(du -sh DemoMusic | awk '{print $1}')"
fi

echo "==> codesign --force --deep --sign -"
codesign --force --deep --sign - "$APP"

echo "==> 完成"
echo "    产物: $APP"
echo "    体积: $(du -sh "$APP" | awk '{print $1}')"
echo "    可执行文件: $(ls -l "$APP/Contents/MacOS/Awake" | awk '{print $5}') bytes"
