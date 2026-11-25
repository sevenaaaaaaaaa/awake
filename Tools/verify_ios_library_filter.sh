#!/bin/bash
# verify_ios_library_filter.sh — 「加了来源，库空了，搜索也用不了」这条抱怨的回归验证
#
# 验证四件事（断言读诊断日志，不靠人看截图）：
#   1. 只看有曲目的来源 → 顶部横幅写「正在只看 X · N 首」，并给出「看全部」
#   2. 只看 0 首来源     → 空态是 sourceEmpty，正文指出刷新路径，按钮是「看全部」
#   3. 带着搜索词        → 忽略来源筛选（scope=all），并明说「已忽略」
#   4. 搜索无结果        → 空态是 noMatch，按钮是「清除搜索」
#
# 用法：
#   bash Tools/verify_ios_library_filter.sh               # 逻辑自检 + 构建 + 模拟器四场景
#   bash Tools/verify_ios_library_filter.sh --no-build    # 复用现有构建
#   bash Tools/verify_ios_library_filter.sh --logic-only  # 只跑纯逻辑（2 秒）
#
# 退出码 0 = 全部通过；1 = 失败（输出断在哪一步）。跑完把曲库文件还原成跑之前那份。
set -uo pipefail
cd "$(dirname "$0")/.."

DEVICE_NAME="iPhone 17 Pro"
OUT=docs/validation/ios-library-filter
DO_BUILD=1
LOGIC_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --no-build) DO_BUILD=0 ;;
    --logic-only) LOGIC_ONLY=1 ;;
  esac
done

FAILS=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }

echo "== 0. 筛选规则自检（不需要模拟器）"
swiftc ios/Awake/AddSourceCopy.swift ios/Awake/LibraryFilter.swift Tools/verify_library_filter.swift \
  -o /tmp/awake-verify-library-filter 2>/tmp/awake-verify-lf.build.log \
  || { cat /tmp/awake-verify-lf.build.log >&2; fail "筛选规则编译失败"; exit 1; }
/tmp/awake-verify-library-filter > /tmp/awake-verify-lf.out || fail "筛选规则自检未通过"
tail -1 /tmp/awake-verify-lf.out
grep -q "^FAIL" /tmp/awake-verify-lf.out && fail "筛选规则有断言失败"

if [ "$LOGIC_ONLY" = 1 ]; then
  if [ "$FAILS" = 0 ]; then echo "PASS 筛选规则自检通过（--logic-only，未跑模拟器）"; exit 0; fi
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
    > /tmp/awake-library-filter-build.log 2>&1 \
    || { tail -20 /tmp/awake-library-filter-build.log >&2; fail "构建失败"; exit 1; }
  pass "构建成功"
fi
if [ ! -d "$APP" ]; then echo "FAIL 没有构建产物；先不加 --no-build 跑一次"; exit 1; fi

echo "== 2. 安装并接管曲库（跑完还原）"
xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
xcrun simctl terminate "$DEVICE_ID" com.seven.awake.ios 2>/dev/null || true
xcrun simctl install "$DEVICE_ID" "$APP"
C=$(xcrun simctl get_app_container "$DEVICE_ID" com.seven.awake.ios data)
LIB="$C/Documents/Awake/library.json"
DIAG="$C/Documents/Awake/diagnostics.log"
mkdir -p "$OUT"
BAK=$(mktemp /tmp/awake-lf-lib.XXXXXX) || { echo "FAIL 无法创建曲库备份"; exit 1; }
HAD_LIB=0
if [ -f "$LIB" ]; then cp "$LIB" "$BAK"; HAD_LIB=1; fi
cleanup() {
  xcrun simctl terminate "$DEVICE_ID" com.seven.awake.ios 2>/dev/null || true
  if [ "$HAD_LIB" = 1 ]; then cp "$BAK" "$LIB"; else rm -f "$LIB"; fi
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
last_filter_line() { new_diag "$1" | grep 'E2E 曲库过滤器' | tail -1; }

echo "== 场景 A：只看一个有曲目的来源"
restart
LINES=$(diag_lines)
SIMCTL_CHILD_AWAKE_E2E_TAB=library SIMCTL_CHILD_AWAKE_E2E_LIBRARY_SOURCE=first \
  xcrun simctl launch "$DEVICE_ID" com.seven.awake.ios >/dev/null
if wait_diag "$LINES" "E2E 曲库过滤器" 40; then
  LINE=$(last_filter_line "$LINES")
  echo "   $LINE"
  case "$LINE" in
    *"scope=source"*) pass "只看来源时确实按来源过滤" ;;
    *) fail "没有按来源过滤：$LINE" ;;
  esac
  case "$LINE" in
    *"正在只看"*) pass "顶部横幅写了「正在只看…」" ;;
    *) fail "没有常显横幅：$LINE" ;;
  esac
  case "$LINE" in
    *"action=看全部"*) : ;;
    *"empty=none"*) : ;;
    *) fail "有曲目时既没有空态也没有出口：$LINE" ;;
  esac
  case "$LINE" in
    *"shown=3"*) pass "列表确实只剩该来源的 3 首" ;;
    *) fail "条数不对：$LINE" ;;
  esac
else
  fail "40 秒内没有过滤器日志，见 $DIAG"
fi
sleep 2
shot library-source-banner.png

echo "== 场景 B：只看一个 0 首来源"
python3 - "$LIB" <<'PY'
import json, sys, os
path = sys.argv[1]
if not os.path.exists(path):
    print("   no library.json"); raise SystemExit
lib = json.load(open(path))
lib["songs"] = []
json.dump(lib, open(path, "w"), ensure_ascii=False)
print("   清空曲目，保留来源 %d 个" % len(lib.get("sources") or []))
PY
restart
LINES=$(diag_lines)
SIMCTL_CHILD_AWAKE_E2E_TAB=library SIMCTL_CHILD_AWAKE_E2E_LIBRARY_SOURCE=first \
  xcrun simctl launch "$DEVICE_ID" com.seven.awake.ios >/dev/null
if wait_diag "$LINES" "E2E 曲库过滤器" 40; then
  LINE=$(last_filter_line "$LINES")
  echo "   $LINE"
  case "$LINE" in
    *"empty=sourceEmpty"*) pass "0 首来源走空态，不假装有内容" ;;
    *) fail "空态类型不对：$LINE" ;;
  esac
  case "$LINE" in
    *"action=看全部"*) pass "空态给出「看全部」这条出口" ;;
    *) fail "空态没有出口：$LINE" ;;
  esac
  case "$LINE" in
    *"还没有曲目"*) pass "横幅先说清这个来源是空的" ;;
    *) fail "横幅没说清现状：$LINE" ;;
  esac
else
  fail "40 秒内没有过滤器日志（0 首场景），见 $DIAG"
fi
sleep 2
shot library-source-empty.png

echo "== 场景 C：带着搜索词（跨来源 + 明说忽略）"
restart
LINES=$(diag_lines)
SIMCTL_CHILD_AWAKE_E2E_TAB=library SIMCTL_CHILD_AWAKE_E2E_LIBRARY_SOURCE=first \
  SIMCTL_CHILD_AWAKE_E2E_LIBRARY_QUERY="no-such-track" \
  xcrun simctl launch "$DEVICE_ID" com.seven.awake.ios >/dev/null
if wait_diag "$LINES" "E2E 曲库过滤器" 40; then
  LINE=$(last_filter_line "$LINES")
  echo "   $LINE"
  case "$LINE" in
    *"scope=all"*) pass "搜索时忽略来源筛选" ;;
    *) fail "搜索仍被来源收窄：$LINE" ;;
  esac
  case "$LINE" in
    *"已忽略"*) pass "横幅明说忽略了哪个筛选" ;;
    *) fail "没有说明忽略了筛选：$LINE" ;;
  esac
  case "$LINE" in
    *"empty=noMatch"*) pass "搜不到时空态是 noMatch" ;;
    *) fail "空态类型不对：$LINE" ;;
  esac
  case "$LINE" in
    *"action=清除搜索"*) pass "空态出口是「清除搜索」" ;;
    *) fail "出口不对：$LINE" ;;
  esac
else
  fail "40 秒内没有过滤器日志（搜索场景），见 $DIAG"
fi
sleep 2
shot library-search-ignores-filter.png

if [ "$FAILS" = 0 ]; then
  echo "PASS 全部断言通过（逻辑自检 + 三个模拟器场景）"
  echo "     截图：$OUT/"
  exit 0
fi
echo "FAIL $FAILS 项失败"
exit 1
