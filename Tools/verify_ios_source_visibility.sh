#!/bin/bash
# verify_ios_source_visibility.sh — 「添加 Plex 来源 → 入库 → 添加页看得见 → 曲库看得见」
#
# 为什么不用 XCUITest：这台机器的 Xcode 27 模拟器测试 runner 起不来
# （xcodebuild 报 DTServiceHubClient failed to bless service hub），见 ios/Awake/Diagnostics.swift。
# 所以这条链用「应用内自检通道 + 落盘断言 + 截图」验证，人也能一眼看回来。
#
# 用法：
#   bash Tools/verify_ios_source_visibility.sh              # 构建 + 验证
#   bash Tools/verify_ios_source_visibility.sh --no-build   # 用现有构建
#
# 退出码 0 = 通过；1 = 失败（会指出断在哪一步）。跑完把曲库文件还原成跑之前那份。
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE_NAME=${DEVICE_NAME:-iPhone 17 Pro}
PORT=${PORT:-32400}
OUT=${OUT:-docs/validation/ios-source-visibility}
DO_BUILD=1
[ "${1:-}" = "--no-build" ] && DO_BUILD=0

DEVICE_ID=$(xcrun simctl list devices available | grep -F "$DEVICE_NAME (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
[ -n "$DEVICE_ID" ] || { echo "FAIL 找不到模拟器：$DEVICE_NAME" >&2; exit 1; }
APP=.build/ios-head/Build/Products/Debug-iphonesimulator/Awake.app
mkdir -p "$OUT"

if [ "$DO_BUILD" = 1 ]; then
  echo "== 构建"
  xcodebuild -project ios/Awake.xcodeproj -scheme AwakeIOS -sdk iphonesimulator \
    -destination "platform=iOS Simulator,id=$DEVICE_ID" \
    -derivedDataPath .build/ios-head -configuration Debug build > /tmp/awake-verify-build.log 2>&1 \
    || { tail -20 /tmp/awake-verify-build.log >&2; echo "FAIL 构建失败" >&2; exit 1; }
fi
[ -d "$APP" ] || { echo "FAIL 没有构建产物：$APP" >&2; exit 1; }

echo "== 假 Plex 服务器 :$PORT"
if ! curl -s -m 1 -o /dev/null -H "X-Plex-Token: e2e-token" "http://127.0.0.1:$PORT/library/sections"; then
  python3 Tools/fake_plex_server.py --port "$PORT" >/tmp/fake_plex.out 2>&1 &
  echo $! > /tmp/fake_plex.pid
  for _ in 1 2 3 4 5 6; do
    curl -s -m 1 -o /dev/null -H "X-Plex-Token: e2e-token" "http://127.0.0.1:$PORT/library/sections" && break
    sleep 1
  done
fi
curl -s -m 2 -H "X-Plex-Token: e2e-token" "http://127.0.0.1:$PORT/library/sections" | grep -q 'type="artist"' \
  || { echo "FAIL 假 Plex 没有响应音乐库" >&2; exit 1; }

xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
xcrun simctl terminate "$DEVICE_ID" com.seven.awake.ios 2>/dev/null || true
xcrun simctl install "$DEVICE_ID" "$APP"
C=$(xcrun simctl get_app_container "$DEVICE_ID" com.seven.awake.ios data)
LIB="$C/Documents/Awake/library.json"
DIAG="$C/Documents/Awake/diagnostics.log"
BAK=$(mktemp /tmp/awake-library-verify.XXXX.json)
[ -f "$LIB" ] && cp "$LIB" "$BAK"
trap '[ -f "$BAK" ] && cp "$BAK" "$LIB" || true' EXIT
LINES_BEFORE=$(wc -l < "$DIAG" 2>/dev/null || echo 0)

echo "== 启动自检通道（真实 scan + 入库）"
SIMCTL_CHILD_AWAKE_E2E_SOURCE="plex|http://127.0.0.1:$PORT|e2e-token" \
SIMCTL_CHILD_AWAKE_E2E_TAB=1 \
  xcrun simctl launch "$DEVICE_ID" com.seven.awake.ios >/dev/null
DONE=0
for _ in $(seq 1 12); do
  sleep 5
  NEW=$(tail -n +$((LINES_BEFORE + 1)) "$DIAG" 2>/dev/null || true)
  echo "   轮询：新增 $(printf '%s' "$NEW" | grep -c '' ) 行"
  if printf '%s' "$NEW" | grep -q "E2E 扫描成功"; then DONE=1; break; fi
  if printf '%s' "$NEW" | grep -q "E2E 扫描失败"; then
    printf '%s\n' "$NEW" >&2; echo "FAIL 扫描失败" >&2; exit 1
  fi
done
[ "$DONE" = 1 ] || { echo "FAIL 60 秒内没有扫描结果，见 $DIAG" >&2; exit 1; }
printf '%s\n' "$NEW" | grep "E2E 扫描成功\|E2E 曲目" | head -4

echo "== 断言落盘 + 截图（曲库）"
sleep 2
xcrun simctl io "$DEVICE_ID" screenshot "$OUT/library.png" >/dev/null 2>&1
python3 - "$LIB" <<'PY'
import json, sys, collections
lib = json.load(open(sys.argv[1]))
songs = lib.get("songs") or []
sources = lib.get("sources") or []
count = collections.Counter(s.get("sourceID") for s in songs)
plex = [s for s in sources if s.get("kind") == "plex"]
fresh = [s for s in plex if count.get(s.get("id"), 0) >= 3]
if not fresh:
    print("FAIL 曲库里没有带曲目的 plex 来源", file=sys.stderr)
    sys.exit(1)
print(f"   落盘：来源 {len(sources)} 个（plex {len(plex)}），曲目 {len(songs)} 首；最新 plex 来源 {count[fresh[-1]['id']]} 首")
PY

echo "== 截图（添加音乐 · 已连接列表）"
xcrun simctl terminate "$DEVICE_ID" com.seven.awake.ios 2>/dev/null || true
sleep 1
SIMCTL_CHILD_AWAKE_E2E_OPEN=addmusic xcrun simctl launch "$DEVICE_ID" com.seven.awake.ios >/dev/null
sleep 6
xcrun simctl io "$DEVICE_ID" screenshot "$OUT/add-music.png" >/dev/null 2>&1
xcrun simctl terminate "$DEVICE_ID" com.seven.awake.ios 2>/dev/null || true

echo "PASS：扫描入库与两个入口的截图都在 $OUT/"
ls -la "$OUT" | tail -3
echo "   人工复核：add-music.png 里「已连接」应有刚加的来源；library.png 里应看到 3 首测试曲。"
