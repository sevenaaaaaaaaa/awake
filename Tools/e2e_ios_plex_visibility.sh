#!/bin/bash
# e2e_ios_plex_visibility.sh — 复现并守住「Plex 连上了，曲库却看不到」
#
# 这条链以前从来没有人跑通过：所有 Plex 修复都是在手写的响应片段上验证的，
# 真机上「连上 → 扫描 → 入库 → 列表里看得见」一直是空白。这个脚本把它变成可重复的一段：
#
#   1. 起一个说 Plex 官方 XML 协议的本地假服务器（Tools/fake_plex_server.py）
#   2. Debug 构建并装进模拟器
#   3. 用 AWAKE_E2E_SOURCE 让 app 自己走一遍 SourceService.scan + 入库
#   4. 读诊断日志与落盘的 library.json，断言曲目真的进来了
#
# 用法:
#   bash Tools/e2e_ios_plex_visibility.sh
#   bash Tools/e2e_ios_plex_visibility.sh --no-build --device "iPhone 17 Pro"
#
# 退出码 0 = 通过；1 = 失败（输出会指出断在哪一步）
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

DEVICE_NAME="iPhone 17 Pro"
PORT=32400
CONFIG=Debug
DO_BUILD=1
DD="${DD:-$ROOT/.build/ios-e2e-derived}"
LOG="/tmp/awake-e2e-plex.log"

while [ $# -gt 0 ]; do
  case "$1" in
    --no-build) DO_BUILD=0; shift ;;
    --device) DEVICE_NAME="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

fail() { echo "FAIL: $*" >&2; exit 1; }
step() { echo "== $*"; }

command -v xcrun >/dev/null || fail "没有 xcrun（需要 Xcode 命令行工具）"

DEVICE_ID=$(xcrun simctl list devices available | grep -F "$DEVICE_NAME (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
[ -n "$DEVICE_ID" ] || fail "找不到模拟器：$DEVICE_NAME"
step "模拟器 $DEVICE_NAME ($DEVICE_ID)"

xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE_ID" -b >/dev/null 2>&1 || true

step "启动假 Plex 服务器 :$PORT"
python3 "$ROOT/Tools/fake_plex_server.py" --port "$PORT" --log "$LOG" >/tmp/awake-e2e-plex-server.out 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if curl -s -m 1 -o /dev/null -H "X-Plex-Token: e2e-token" "http://127.0.0.1:$PORT/library/sections"; then break; fi
  sleep 1
done
curl -s -m 2 -H "X-Plex-Token: e2e-token" "http://127.0.0.1:$PORT/library/sections" | grep -q "type=\"artist\"" \
  || fail "假 Plex 服务器没有响应音乐库"
step "假 Plex 就绪"

if [ "$DO_BUILD" = "1" ]; then
  APP="$DD/Build/Products/$CONFIG-iphonesimulator/Awake.app"
  step "构建（$CONFIG）"
  if ! xcodebuild -project ios/Awake.xcodeproj -scheme AwakeIOS -sdk iphonesimulator \
      -destination "platform=iOS Simulator,id=$DEVICE_ID" \
      -derivedDataPath "$DD" -configuration "$CONFIG" build >/tmp/awake-e2e-build.log 2>&1; then
    tail -30 /tmp/awake-e2e-build.log >&2
    fail "构建失败，日志 /tmp/awake-e2e-build.log"
  fi
else
  APP="$DD/Build/Products/$CONFIG-iphonesimulator/Awake.app"
fi
[ -d "$APP" ] || fail "找不到构建产物：$APP"

step "安装并干净启动"
xcrun simctl terminate "$DEVICE_ID" com.seven.awake.ios 2>/dev/null || true
xcrun simctl uninstall "$DEVICE_ID" com.seven.awake.ios 2>/dev/null || true
xcrun simctl install "$DEVICE_ID" "$APP"
SIMCTL_CHILD_AWAKE_E2E_SOURCE="plex|http://127.0.0.1:$PORT|e2e-token" \
  xcrun simctl launch "$DEVICE_ID" com.seven.awake.ios >/dev/null

step "等待扫描结果"
CONTAINER=""
DIAG=""
for _ in $(seq 1 12); do
  sleep 5
  CONTAINER=$(xcrun simctl get_app_container "$DEVICE_ID" com.seven.awake.ios data 2>/dev/null || true)
  [ -n "$CONTAINER" ] || continue
  DIAG="$CONTAINER/Documents/Awake/diagnostics.log"
  if [ -f "$DIAG" ] && grep -q "E2E 扫描" "$DIAG"; then break; fi
done
[ -f "$DIAG" ] || fail "没有诊断日志：$DIAG"
grep "E2E" "$DIAG" | tail -8

grep -q "E2E 扫描成功" "$DIAG" || {
  echo "--- 假 Plex 收到的请求 ---" >&2
  cat "$LOG" >&2 || true
  fail "扫描没有成功，见上面的诊断日志"
}

step "核对入库结果"
LIB="$CONTAINER/Documents/Awake/library.json"
[ -f "$LIB" ] || fail "没有落盘曲库：$LIB"
python3 - "$LIB" <<'PY' || exit 1
import json, sys
lib = json.load(open(sys.argv[1]))
songs = lib.get("songs", [])
sources = lib.get("sources", [])
plex = [s for s in sources if s.get("kind") == "plex"]
if not plex:
    print("FAIL: 落盘曲库里没有 plex 来源", file=sys.stderr); sys.exit(1)
sid = plex[0]["id"]
mine = [s for s in songs if s.get("sourceID") == sid]
print(f"落盘：来源 {len(sources)} 个（plex {len(plex)}），曲目 {len(songs)} 首，其中该来源 {len(mine)} 首")
for s in mine:
    print(f"  - {s.get('title')} / {s.get('artist')} / locator={s.get('locator')}")
if len(mine) != 3:
    print("FAIL: 期望 3 首，实际 %d 首" % len(mine), file=sys.stderr); sys.exit(1)
for s in mine:
    if not s.get("locator", "").startswith("/library/parts/"):
        print("FAIL: locator 不是 Plex 资源路径：%r" % s.get("locator"), file=sys.stderr); sys.exit(1)
PY

step "核对客户端请求"
grep -q "GET /library/sections token=yes" "$LOG" || fail "客户端没有带 Token 请求音乐库"
grep -q "type=10" "$LOG" || fail "客户端没有按 type=10 拉曲目"

echo "PASS: Plex 连接 → 扫描 → 入库 全链路通过（3 首，来源与曲目都对得上）"
echo "     下一步真人验收：在模拟器里点「曲库」，来源筛选应显示「<来源名> · 3 首」，列表里能看到 3 首。"
