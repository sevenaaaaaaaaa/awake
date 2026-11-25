#!/bin/bash
# verify_ios_add_source_entry.sh — 「添加页 = 来源入口」的一条可重跑验证
#
# 验证这轮交付的四件事：
#   1. 有曲目的行：文案说清「N 首 · 点这里进曲库」
#   2. 点行（与手指点击同一个函数）：切到曲库并筛到这个来源
#   3. 0 首的行：文案说清「还没有曲目」与下一步；点进去的曲库空态也说下一步
#   4. 连接失败：弹窗内与弹窗之外都写「没有加入」
#
# 前置：Xcode + iOS 模拟器；不需要真实 Plex（用 Tools/fake_plex_server.py）。
# 用法：
#   bash Tools/verify_ios_add_source_entry.sh              # 文案 + 构建 + 模拟器三场景
#   bash Tools/verify_ios_add_source_entry.sh --no-build   # 复用现有构建
#   bash Tools/verify_ios_add_source_entry.sh --copy-only  # 只跑文案（2 秒）
#
# 退出码 0 = 全部通过；1 = 失败（输出断在哪一步）。跑完把曲库文件还原成跑之前那份。
set -uo pipefail
cd "$(dirname "$0")/.."

DEVICE_NAME="iPhone 17 Pro"
PORT=32400
OUT=docs/validation/ios-add-source-entry
DO_BUILD=1
COPY_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --no-build) DO_BUILD=0 ;;
    --copy-only) COPY_ONLY=1 ;;
  esac
done

FAILS=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }

echo "== 0. 文案自检（不需要模拟器）"
swiftc ios/Awake/AddSourceCopy.swift Tools/verify_add_source_copy.swift \
  -o /tmp/awake-verify-copy 2>/tmp/awake-verify-copy.build.log \
  || { cat /tmp/awake-verify-copy.build.log >&2; fail "文案自检编译失败"; exit 1; }
/tmp/awake-verify-copy || fail "文案自检未通过"

if [ "$COPY_ONLY" = 1 ]; then
  if [ "$FAILS" = 0 ]; then echo "PASS 文案自检通过（--copy-only，未跑模拟器）"; exit 0; fi
  echo "FAIL $FAILS 项失败"; exit 1
fi

echo "== 1. 构建"
APP=.build/ios-head/Build/Products/Debug-iphonesimulator/Awake.app
DEVICE_ID=$(xcrun simctl list devices available | grep -F "$DEVICE_NAME (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
if [ -z "$DEVICE_ID" ]; then echo "FAIL 找不到模拟器：$DEVICE_NAME"; exit 1; fi
if [ "$DO_BUILD" = 1 ]; then
  xcodebuild -project ios/Awake.xcodeproj -scheme AwakeIOS -sdk iphonesimulator \
    -destination "platform=iOS Simulator,id=$DEVICE_ID" \
    -derivedDataPath .build/ios-head -configuration Debug build \
    > /tmp/awake-add-source-build.log 2>&1 \
    || { tail -20 /tmp/awake-add-source-build.log >&2; fail "构建失败"; exit 1; }
  pass "构建成功"
fi
if [ ! -d "$APP" ]; then echo "FAIL 没有构建产物；先不加 --no-build 跑一次"; exit 1; fi

echo "== 2. 假 Plex 服务器 :$PORT"
FAKE_PID=""
if ! curl -s -m 1 -o /dev/null -H "X-Plex-Token: e2e-token" "http://127.0.0.1:$PORT/library/sections"; then
  python3 Tools/fake_plex_server.py --port "$PORT" --log /tmp/fake_plex.log >/tmp/fake_plex.out 2>&1 &
  FAKE_PID=$!
  for _ in 1 2 3 4 5 6; do
    curl -s -m 1 -o /dev/null -H "X-Plex-Token: e2e-token" "http://127.0.0.1:$PORT/library/sections" && break
    sleep 1
  done
fi
curl -s -m 2 -H "X-Plex-Token: e2e-token" "http://127.0.0.1:$PORT/library/sections" | grep -q 'type="artist"' \
  || { echo "FAIL 假 Plex 没有响应音乐库"; exit 1; }

echo "== 3. 安装并接管曲库（跑完还原）"
xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
xcrun simctl terminate "$DEVICE_ID" com.seven.awake.ios 2>/dev/null || true
xcrun simctl install "$DEVICE_ID" "$APP"
C=$(xcrun simctl get_app_container "$DEVICE_ID" com.seven.awake.ios data)
LIB="$C/Documents/Awake/library.json"
DIAG="$C/Documents/Awake/diagnostics.log"
mkdir -p "$OUT"
BAK=$(mktemp /tmp/awake-add-source-lib.XXXXXX) || { echo "FAIL 无法创建曲库备份"; exit 1; }
HAD_LIB=0
if [ -f "$LIB" ]; then cp "$LIB" "$BAK"; HAD_LIB=1; fi
cleanup() {
  xcrun simctl terminate "$DEVICE_ID" com.seven.awake.ios 2>/dev/null || true
  if [ "$HAD_LIB" = 1 ]; then cp "$BAK" "$LIB"; else rm -f "$LIB"; fi
  if [ -n "$FAKE_PID" ]; then kill "$FAKE_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT

diag_lines() { if [ -f "$DIAG" ]; then wc -l < "$DIAG" | tr -d ' '; else echo 0; fi; }
new_diag() { tail -n +$(( $1 + 1 )) "$DIAG" 2>/dev/null; }
restart() {
  xcrun simctl terminate "$DEVICE_ID" com.seven.awake.ios 2>/dev/null || true
  sleep 1
}
wait_diag() { # since pattern timeout
  local since="$1" pattern="$2" timeout="$3" start
  start=$(date +%s)
  while [ $(( $(date +%s) - start )) -lt "$timeout" ]; do
    if new_diag "$since" | grep -qF "$pattern"; then return 0; fi
    sleep 1
  done
  return 1
}
shot() { xcrun simctl io "$DEVICE_ID" screenshot "$OUT/$1" >/dev/null 2>&1 || true; }

echo "== 场景 A0：扫描 3 首入库"
rm -f "$LIB"
restart
LINES=$(diag_lines)
SIMCTL_CHILD_AWAKE_E2E_SOURCE="plex|http://127.0.0.1:$PORT|e2e-token" \
  xcrun simctl launch "$DEVICE_ID" com.seven.awake.ios >/dev/null
if wait_diag "$LINES" "E2E 扫描成功" 60; then
  if new_diag "$LINES" | grep -q "E2E 扫描成功 songs=3"; then
    pass "来源连上并入库 3 首"
  else
    fail "扫描成功但曲目数不是 3：$(new_diag "$LINES" | grep 'E2E 扫描成功' | tail -1)"
  fi
else
  fail "60 秒内没有扫描结果，见 $DIAG"
fi

echo "== 场景 A1：添加页每一行的文案（有曲目）"
restart
LINES=$(diag_lines)
SIMCTL_CHILD_AWAKE_E2E_OPEN=addmusic SIMCTL_CHILD_AWAKE_E2E_LOG_ROWS=1 \
  xcrun simctl launch "$DEVICE_ID" com.seven.awake.ios >/dev/null
if wait_diag "$LINES" "E2E 添加页行" 30; then
  if new_diag "$LINES" | grep -qF "text=Plex · 3 首 · 点这里进曲库"; then
    pass "有曲目的行写了「3 首 · 点这里进曲库」"
  else
    fail "行文案不对：$(new_diag "$LINES" | grep 'E2E 添加页行' | tail -1)"
  fi
else
  fail "添加页没有打印行文案"
fi
sleep 2
shot add-source-3.png

echo "== 场景 A2：点行 -> 曲库筛到这个来源"
restart
LINES=$(diag_lines)
SIMCTL_CHILD_AWAKE_E2E_OPEN=addmusic SIMCTL_CHILD_AWAKE_E2E_PICK_SOURCE=1 \
  xcrun simctl launch "$DEVICE_ID" com.seven.awake.ios >/dev/null
if wait_diag "$LINES" "E2E 曲库筛选" 30; then
  if new_diag "$LINES" | grep -q "E2E 选择来源 .*count=3"; then
    pass "点行走了与手指点击相同的选择函数"
  else
    fail "没有看到选择来源的日志"
  fi
  if new_diag "$LINES" | grep -q "E2E 曲库筛选 .*count=3"; then
    pass "曲库已筛到这个来源（3 首）"
  else
    fail "曲库筛选不对：$(new_diag "$LINES" | grep 'E2E 曲库筛选' | tail -1)"
  fi
else
  fail "点行后曲库没有收到筛选"
fi
sleep 2
shot library-selected.png

echo "== 场景 B：0 首的行与曲库空态"
python3 - "$LIB" <<'PY'
import json, sys
path = sys.argv[1]
lib = json.load(open(path))
lib["songs"] = []
json.dump(lib, open(path, "w"), ensure_ascii=False)
print("   清空曲目，保留来源 %d 个" % len(lib.get("sources") or []))
PY
restart
LINES=$(diag_lines)
SIMCTL_CHILD_AWAKE_E2E_OPEN=addmusic SIMCTL_CHILD_AWAKE_E2E_LOG_ROWS=1 \
  xcrun simctl launch "$DEVICE_ID" com.seven.awake.ios >/dev/null
if wait_diag "$LINES" "E2E 添加页行" 30; then
  if new_diag "$LINES" | grep -qF "count=0 text=Plex · 还没有曲目 · 到「设置 → 音乐来源」刷新或移除"; then
    pass "0 首的行写清了现状与下一步"
  else
    fail "0 首行文案不对：$(new_diag "$LINES" | grep 'E2E 添加页行' | tail -1)"
  fi
else
  fail "0 首场景没有打印行文案"
fi
sleep 2
shot add-source-zero.png

restart
LINES=$(diag_lines)
SIMCTL_CHILD_AWAKE_E2E_OPEN=addmusic SIMCTL_CHILD_AWAKE_E2E_PICK_SOURCE=1 \
  xcrun simctl launch "$DEVICE_ID" com.seven.awake.ios >/dev/null
if wait_diag "$LINES" "E2E 曲库筛选" 30; then
  if new_diag "$LINES" | grep -q "empty=.*还没有曲目.*刷新"; then
    pass "0 首来源的曲库空态也给了下一步"
  else
    fail "曲库空态文案不对：$(new_diag "$LINES" | grep 'E2E 曲库筛选' | tail -1)"
  fi
else
  fail "0 首点行后曲库没有收到筛选"
fi
sleep 2
shot library-zero.png

echo "== 场景 C1：连接失败（弹窗内 + 弹窗之外的文案）"
restart
LINES=$(diag_lines)
SIMCTL_CHILD_AWAKE_E2E_OPEN=addmusic SIMCTL_CHILD_AWAKE_E2E_ADD_FAIL=1 \
  xcrun simctl launch "$DEVICE_ID" com.seven.awake.ios >/dev/null
if wait_diag "$LINES" "E2E 失败后添加页" 40; then
  LINE=$(new_diag "$LINES" | grep -F "E2E 失败 inSheet=" | tail -1)
  if echo "$LINE" | grep -q "inSheet=没有加入："; then
    pass "弹窗内写的是「没有加入」"
  else
    fail "弹窗内文案不对：$LINE"
  fi
  if echo "$LINE" | grep -q "outside=.*没有加入："; then
    pass "留给添加页的文案也是「没有加入」"
  else
    fail "弹窗之外文案不对：$LINE"
  fi
  AFTER=$(new_diag "$LINES" | grep -F "E2E 失败后添加页" | tail -1)
  if echo "$AFTER" | grep -q "message=.*没有加入："; then
    pass "添加页拿到了失败的文案"
  else
    fail "添加页没有拿到失败文案：$AFTER"
  fi
else
  fail "失败路径没有跑完（见 $DIAG）"
fi
sleep 2
shot add-source-failed.png

echo "== 场景 C2：关掉编辑器后，添加页顶部仍写着「没有加入」"
restart
LINES=$(diag_lines)
SIMCTL_CHILD_AWAKE_E2E_OPEN=addmusic \
SIMCTL_CHILD_AWAKE_E2E_SEED_MESSAGE="「失败样例」没有加入：连接被拒绝" \
  xcrun simctl launch "$DEVICE_ID" com.seven.awake.ios >/dev/null
if wait_diag "$LINES" "E2E 最近一次操作=" 30; then
  if new_diag "$LINES" | grep -q "E2E 最近一次操作=.*没有加入："; then
    pass "添加页顶部渲染的仍是「没有加入」"
  else
    fail "添加页顶部文案不对：$(new_diag "$LINES" | grep 'E2E 最近一次操作=' | tail -1)"
  fi
else
  fail "添加页没有渲染失败文案"
fi
sleep 2
shot add-source-failed-outside.png

echo "== 产物：$OUT/"
ls -la "$OUT" | tail -5
if [ "$FAILS" = 0 ]; then
  echo "PASS 全部断言通过（文案自检 + 四个模拟器场景）"
  exit 0
fi
echo "FAIL $FAILS 项失败"
exit 1
