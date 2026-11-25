#!/bin/bash
# verify_ios_tuning_hub.sh — 「调音」合并入口 + 播放页配色的可重跑验证
#
#  1. 构建（--no-build 可跳过）
#  2. 装一份可播放的静音音频进曲库，让播放页真的有内容可截
#  3. 截两张图：调音页（对话/曲线/记录三段）、播放页（配色与封面进度线）
#  4. 断言读诊断日志：tab 数已经是 4，启动确实落在指定页
#
# 用法：
#   bash Tools/verify_ios_tuning_hub.sh
#   bash Tools/verify_ios_tuning_hub.sh --no-build
set -uo pipefail
cd "$(dirname "$0")/.."

DEVICE_NAME="iPhone 17 Pro"
OUT=docs/validation/ios-tuning-hub
DO_BUILD=1
for arg in "$@"; do
  case "$arg" in --no-build) DO_BUILD=0 ;; esac
done

FAILS=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }

echo "== 1. 构建"
APP=.build/ios-head/Build/Products/Debug-iphonesimulator/Awake.app
DEVICE_ID=$(xcrun simctl list devices available | grep -F "$DEVICE_NAME (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
if [ -z "$DEVICE_ID" ]; then echo "FAIL 找不到模拟器：$DEVICE_NAME"; exit 1; fi
if [ "$DO_BUILD" = 1 ]; then
  xcodebuild -project ios/Awake.xcodeproj -scheme AwakeIOS -sdk iphonesimulator \
    -destination "platform=iOS Simulator,id=$DEVICE_ID" \
    -derivedDataPath .build/ios-head -configuration Debug build \
    > /tmp/awake-tuning-build.log 2>&1 \
    || { tail -20 /tmp/awake-tuning-build.log >&2; fail "构建失败"; exit 1; }
  pass "构建成功"
fi
[ -d "$APP" ] || { echo "FAIL 没有构建产物"; exit 1; }

echo "== 2. 安装并准备一份能播的曲库"
xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
xcrun simctl terminate "$DEVICE_ID" com.seven.awake.ios 2>/dev/null || true
xcrun simctl install "$DEVICE_ID" "$APP"
C=$(xcrun simctl get_app_container "$DEVICE_ID" com.seven.awake.ios data)
LIB="$C/Documents/Awake/library.json"
DIAG="$C/Documents/Awake/diagnostics.log"
MUSIC="$C/Documents/Awake/Music"
mkdir -p "$OUT" "$MUSIC"
BAK=$(mktemp /tmp/awake-tuning-lib.XXXXXX) || { echo "FAIL 无法备份曲库"; exit 1; }
HAD_LIB=0
if [ -f "$LIB" ]; then cp "$LIB" "$BAK"; HAD_LIB=1; fi
cleanup() {
  xcrun simctl terminate "$DEVICE_ID" com.seven.awake.ios 2>/dev/null || true
  if [ "$HAD_LIB" = 1 ]; then cp "$BAK" "$LIB"; else rm -f "$LIB"; fi
  rm -f "$MUSIC/e2e-tone.wav"
}
trap cleanup EXIT

[ "$HAD_LIB" = 1 ] || { echo "FAIL 没有曲库可改，先跑 verify_ios_add_source_entry.sh"; exit 1; }

python3 - "$LIB" "$MUSIC/e2e-tone.wav" <<'PY'
import json, sys, wave
lib_path, wav_path = sys.argv[1], sys.argv[2]
w = wave.open(wav_path, "wb")
w.setnchannels(1)
w.setsampwidth(2)
w.setframerate(44100)
w.writeframes(b"\x00\x00" * 44100 * 5)
w.close()
lib = json.load(open(lib_path))
songs = lib.get("songs") or []
if not songs:
    print("   FAIL 曲库为空"); raise SystemExit(1)
songs[0]["file"] = "e2e-tone.wav"
lib["songs"] = songs
json.dump(lib, open(lib_path, "w"), ensure_ascii=False)
print("   静音音频 5 秒已放好，给第 1 首挂了 file")
PY
[ $? -eq 0 ] || { echo "FAIL 准备音频失败"; exit 1; }

diag_lines() { if [ -f "$DIAG" ]; then wc -l < "$DIAG" | tr -d ' '; else echo 0; fi; }
new_diag() { tail -n +$(( $1 + 1 )) "$DIAG" 2>/dev/null; }
wait_diag() {
  local since="$1" pattern="$2" timeout="$3" start
  start=$(date +%s)
  while [ $(( $(date +%s) - start )) -lt "$timeout" ]; do
    if new_diag "$since" | grep -qF "$pattern"; then return 0; fi
    sleep 1
  done
  return 1
}

echo "== 场景 A：调音页（合并入口）"
xcrun simctl terminate "$DEVICE_ID" com.seven.awake.ios 2>/dev/null || true
LINES=$(diag_lines)
SIMCTL_CHILD_AWAKE_E2E_TAB=tuning xcrun simctl launch "$DEVICE_ID" com.seven.awake.ios >/dev/null
if wait_diag "$LINES" "E2E 启动" 40; then
  LINE=$(new_diag "$LINES" | grep "E2E 启动" | tail -1)
  echo "   $LINE"
  case "$LINE" in
    *"tabs=4"*) pass "底部入口从 5 个变 4 个" ;;
    *) fail "入口数不对：$LINE" ;;
  esac
  case "$LINE" in
    *"tab=2"*) pass "启动落在第 3 个入口（调音）" ;;
    *) fail "没有落在调音页：$LINE" ;;
  esac
else
  fail "40 秒内没有启动日志，见 $DIAG"
fi
sleep 3
xcrun simctl io "$DEVICE_ID" screenshot "$OUT/tuning-hub.png" >/dev/null 2>&1 || true

echo "== 场景 B：播放页（配色 + 封面进度线）"
xcrun simctl terminate "$DEVICE_ID" com.seven.awake.ios 2>/dev/null || true
LINES=$(diag_lines)
SIMCTL_CHILD_AWAKE_E2E_TAB=nowplaying xcrun simctl launch "$DEVICE_ID" com.seven.awake.ios >/dev/null
if wait_diag "$LINES" "E2E 启动" 40; then
  LINE=$(new_diag "$LINES" | grep "E2E 启动" | tail -1)
  echo "   $LINE"
  case "$LINE" in
    *"scene=nowplaying"*) pass "播放页场景已启动" ;;
    *) fail "场景没对上：$LINE" ;;
  esac
else
  fail "40 秒内没有启动日志（播放页）"
fi
sleep 5
xcrun simctl io "$DEVICE_ID" screenshot "$OUT/now-playing.png" >/dev/null 2>&1 || true

if [ -f "$OUT/now-playing.png" ]; then
  BYTES=$(wc -c < "$OUT/now-playing.png" | tr -d ' ')
  [ "$BYTES" -gt 30000 ] && pass "播放页截图已生成（$BYTES 字节）" || fail "播放页截图异常（$BYTES 字节）"
fi

if [ "$FAILS" = 0 ]; then
  echo "PASS 全部断言通过"
  echo "     截图：$OUT/tuning-hub.png · $OUT/now-playing.png"
  exit 0
fi
echo "FAIL $FAILS 项失败"
exit 1
