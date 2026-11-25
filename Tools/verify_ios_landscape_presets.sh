#!/bin/bash
# verify_ios_landscape_presets.sh — 横屏布局与风格预设的可重跑验证
#
#  1. 装一份能播的静音音频（横屏舞台要有内容才看得出载体在转）
#  2. 场景 A：AWAKE_E2E_TAB=landscape  → 按横屏尺寸渲染一份布局，截图
#  3. 场景 B：AWAKE_E2E_TAB=tuning + AWAKE_E2E_SEGMENT=1 → 曲线段，截图预设条
#  4. 断言：预设自检 21 项、两张截图非空
set -uo pipefail
cd "$(dirname "$0")/.."

DEVICE_NAME="iPhone 17 Pro"
OUT=docs/validation/ios-landscape-presets
DO_BUILD=1
for arg in "$@"; do
  case "$arg" in --no-build) DO_BUILD=0 ;; esac
done

FAILS=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }

echo "== 0. 预设自检"
swiftc ios/Awake/TuningPresets.swift Tools/verify_tuning_presets.swift \
  -o /tmp/awake-verify-presets 2>/tmp/awake-presets.build.log \
  || { cat /tmp/awake-presets.build.log >&2; fail "预设编译失败"; exit 1; }
/tmp/awake-verify-presets > /tmp/awake-presets.out || fail "预设自检未通过"
tail -1 /tmp/awake-presets.out
grep -q "^FAIL" /tmp/awake-presets.out && fail "预设自检有断言失败"

echo "== 1. 构建"
APP=.build/ios-head/Build/Products/Debug-iphonesimulator/Awake.app
DEVICE_ID=$(xcrun simctl list devices available | grep -F "$DEVICE_NAME (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
if [ "$DO_BUILD" = 1 ]; then
  xcodebuild -project ios/Awake.xcodeproj -scheme AwakeIOS -sdk iphonesimulator \
    -destination "platform=iOS Simulator,id=$DEVICE_ID" \
    -derivedDataPath .build/ios-head -configuration Debug build \
    > /tmp/awake-landscape-build.log 2>&1 \
    || { tail -20 /tmp/awake-landscape-build.log >&2; fail "构建失败"; exit 1; }
  pass "构建成功"
fi
[ -d "$APP" ] || { echo "FAIL 没有构建产物"; exit 1; }

echo "== 2. 安装并准备曲库"
xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
xcrun simctl terminate "$DEVICE_ID" com.seven.awake.ios 2>/dev/null || true
xcrun simctl install "$DEVICE_ID" "$APP"
C=$(xcrun simctl get_app_container "$DEVICE_ID" com.seven.awake.ios data)
LIB="$C/Documents/Awake/library.json"
DIAG="$C/Documents/Awake/diagnostics.log"
MUSIC="$C/Documents/Awake/Music"
mkdir -p "$OUT" "$MUSIC"
BAK=$(mktemp /tmp/awake-lp-lib.XXXXXX) || { echo "FAIL 备份失败"; exit 1; }
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
w.writeframes(b"\x00\x00" * 44100 * 8)
w.close()
lib = json.load(open(lib_path))
songs = lib.get("songs") or []
if not songs:
    print("   FAIL 曲库为空"); raise SystemExit(1)
songs[0]["file"] = "e2e-tone.wav"
lib["songs"] = songs
json.dump(lib, open(lib_path, "w"), ensure_ascii=False)
print("   静音音频 8 秒已放好")
PY
[ $? -eq 0 ] || { echo "FAIL 准备音频失败"; exit 1; }

diag_lines() { if [ -f "$DIAG" ]; then wc -l < "$DIAG" | tr -d ' '; else echo 0; fi; }

echo "== 场景 A：横屏布局"
xcrun simctl terminate "$DEVICE_ID" com.seven.awake.ios 2>/dev/null || true
SIMCTL_CHILD_AWAKE_E2E_TAB=landscape xcrun simctl launch "$DEVICE_ID" com.seven.awake.ios >/dev/null
sleep 6
xcrun simctl io "$DEVICE_ID" screenshot "$OUT/landscape-player.png" >/dev/null 2>&1 || true
if [ -f "$OUT/landscape-player.png" ]; then
  B=$(wc -c < "$OUT/landscape-player.png" | tr -d ' ')
  [ "$B" -gt 30000 ] && pass "横屏舞台截图已生成（$B 字节）" || fail "横屏截图异常（$B 字节）"
else
  fail "横屏截图没有生成"
fi

echo "== 场景 B：曲线段与风格预设"
xcrun simctl terminate "$DEVICE_ID" com.seven.awake.ios 2>/dev/null || true
SIMCTL_CHILD_AWAKE_E2E_TAB=tuning SIMCTL_CHILD_AWAKE_E2E_SEGMENT=1 \
  xcrun simctl launch "$DEVICE_ID" com.seven.awake.ios >/dev/null
sleep 5
xcrun simctl io "$DEVICE_ID" screenshot "$OUT/eq-presets.png" >/dev/null 2>&1 || true
if [ -f "$OUT/eq-presets.png" ]; then
  B=$(wc -c < "$OUT/eq-presets.png" | tr -d ' ')
  [ "$B" -gt 30000 ] && pass "曲线段截图已生成（$B 字节）" || fail "曲线段截图异常（$B 字节）"
else
  fail "曲线段截图没有生成"
fi

if [ "$FAILS" = 0 ]; then
  echo "PASS 全部断言通过"
  echo "     截图：$OUT/landscape-player.png · $OUT/eq-presets.png"
  exit 0
fi
echo "FAIL $FAILS 项失败"
exit 1
