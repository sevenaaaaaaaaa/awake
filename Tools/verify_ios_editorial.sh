#!/bin/bash
# verify_ios_editorial.sh — 首页「编排」的可重跑验证
#
#  1. 规则自检：今日精选 / 专题 / 通勤时长的纯逻辑断言（swiftc，2 秒）
#  2. 构建（--no-build 可跳过）
#  3. 模拟器：往曲库注入一份 12 首的演示库，断言首页真的排出了
#     今日精选 + 多组专题 + 歌单，并截图。跑完把曲库还原。
#
# 用法：
#   bash Tools/verify_ios_editorial.sh              # 全跑
#   bash Tools/verify_ios_editorial.sh --no-build   # 复用构建
#   bash Tools/verify_ios_editorial.sh --logic-only # 只跑规则
set -uo pipefail
cd "$(dirname "$0")/.."

DEVICE_NAME="iPhone 17 Pro"
OUT=docs/validation/ios-editorial-home
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

echo "== 0. 编排规则自检"
swiftc ios/Awake/Editorial.swift Tools/verify_editorial.swift \
  -o /tmp/awake-verify-editorial 2>/tmp/awake-editorial.build.log \
  || { cat /tmp/awake-editorial.build.log >&2; fail "编排规则编译失败"; exit 1; }
/tmp/awake-verify-editorial > /tmp/awake-editorial.out || fail "编排规则自检未通过"
tail -1 /tmp/awake-editorial.out
grep -q "^FAIL" /tmp/awake-editorial.out && fail "编排规则有断言失败"

if [ "$LOGIC_ONLY" = 1 ]; then
  if [ "$FAILS" = 0 ]; then echo "PASS 编排规则自检通过（--logic-only）"; exit 0; fi
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
    > /tmp/awake-editorial-build.log 2>&1 \
    || { tail -20 /tmp/awake-editorial-build.log >&2; fail "构建失败"; exit 1; }
  pass "构建成功"
fi
[ -d "$APP" ] || { echo "FAIL 没有构建产物"; exit 1; }

echo "== 2. 安装并注入演示曲库（跑完还原）"
xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
xcrun simctl terminate "$DEVICE_ID" com.seven.awake.ios 2>/dev/null || true
xcrun simctl install "$DEVICE_ID" "$APP"
C=$(xcrun simctl get_app_container "$DEVICE_ID" com.seven.awake.ios data)
LIB="$C/Documents/Awake/library.json"
DIAG="$C/Documents/Awake/diagnostics.log"
mkdir -p "$OUT"
BAK=$(mktemp /tmp/awake-editorial-lib.XXXXXX) || { echo "FAIL 无法创建曲库备份"; exit 1; }
HAD_LIB=0
if [ -f "$LIB" ]; then cp "$LIB" "$BAK"; HAD_LIB=1; fi
cleanup() {
  xcrun simctl terminate "$DEVICE_ID" com.seven.awake.ios 2>/dev/null || true
  if [ "$HAD_LIB" = 1 ]; then cp "$BAK" "$LIB"; else rm -f "$LIB"; fi
}
trap cleanup EXIT

if [ "$HAD_LIB" = 0 ]; then echo "FAIL 没有曲库文件可克隆，先跑一次 verify_ios_add_source_entry.sh"; exit 1; fi
python3 - "$LIB" <<'PY'
import json, sys, time
REFRENCE = 978307200.0  # Swift 默认 Date 编码：2001-01-01 起的秒
path = sys.argv[1]
lib = json.load(open(path))
base = (lib.get("songs") or [None])[0]
if not base:
    print("   FAIL 曲库为空，无法克隆字段"); raise SystemExit(1)
now = time.time()
specs = [
    ("夜航 · 一", "Awake Lab", "夜航", 320, False, 2),
    ("夜航 · 二", "Awake Lab", "夜航", 300, True, 2),
    ("夜航 · 三", "Awake Lab", "夜航", 280, False, 3),
    ("夜航 · 四", "Awake Lab", "夜航", 260, False, 4),
    ("电波 · 一", "Signal Test", "电波", 240, True, 10),
    ("电波 · 二", "Signal Test", "电波", 220, False, 10),
    ("电波 · 三", "Signal Test", "电波", 200, False, 12),
    ("低音 · 一", "Low End", "低频", 420, True, 40),
    ("低音 · 二", "Low End", "低频", 380, False, 40),
    ("低音 · 三", "Low End", "低频", 360, True, 45),
    ("清晨 · 一", "Dawn", "清晨", 180, False, 60),
    ("清晨 · 二", "Dawn", "清晨", 160, False, 60),
]
songs = []
for i, (title, artist, album, duration, favorite, days) in enumerate(specs):
    s = dict(base)
    s.update({
        "id": "e2e-%02d" % i,
        "title": title,
        "artist": artist,
        "album": album,
        "duration": duration,
        "favorite": favorite,
        "addedAt": (now - days * 86400) - REFRENCE,
        "locator": "",
    })
    songs.append(s)
lib["songs"] = songs
lib["listens"] = []
lib["playlists"] = [
    {"id": "e2e-pl-1", "name": "深夜 30 分钟", "songIDs": ["e2e-07", "e2e-08", "e2e-09"],
     "createdAt": now - REFRENCE, "note": "演示歌单"},
    {"id": "e2e-pl-2", "name": "通勤", "songIDs": ["e2e-00", "e2e-01", "e2e-02"],
     "createdAt": now - REFRENCE, "note": "演示歌单"},
]
json.dump(lib, open(path, "w"), ensure_ascii=False)
print("   注入 %d 首、%d 个歌单" % (len(songs), len(lib["playlists"])))
PY
[ $? -eq 0 ] || { echo "FAIL 注入演示库失败"; exit 1; }

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

echo "== 3. 首页编排"
xcrun simctl terminate "$DEVICE_ID" com.seven.awake.ios 2>/dev/null || true
LINES=$(diag_lines)
SIMCTL_CHILD_AWAKE_E2E_TAB=home xcrun simctl launch "$DEVICE_ID" com.seven.awake.ios >/dev/null
if wait_diag "$LINES" "E2E 首页编排" 40; then
  LINE=$(new_diag "$LINES" | grep 'E2E 首页编排' | tail -1)
  echo "   $LINE"
  case "$LINE" in
    *"songs=12"*) pass "读到 12 首演示库" ;;
    *) fail "曲目数不对：$LINE" ;;
  esac
  case "$LINE" in
    *"pick=none"*) fail "没有选出今日精选：$LINE" ;;
    *) pass "今日精选选出了具体一首" ;;
  esac
  case "$LINE" in
    *"你收下了它"*|*"最近 14 天"*|*"最长"*|*"从这里开始"*) pass "精选留下了理由" ;;
    *) fail "精选没有理由：$LINE" ;;
  esac
  case "$LINE" in
    *"collections=0"*) fail "一组专题都没排出来：$LINE" ;;
    *) pass "排出了专题" ;;
  esac
  case "$LINE" in
    *"ids="*"unplayed"*) pass "有「还没评测过的」专题" ;;
    *) fail "缺 unplayed 专题：$LINE" ;;
  esac
  case "$LINE" in
    *"favorites"*) pass "有收藏专题" ;;
    *) fail "缺收藏专题：$LINE" ;;
  esac
  case "$LINE" in
    *"commute"*) pass "有通勤专题（时长已凑够）" ;;
    *) fail "缺通勤专题：$LINE" ;;
  esac
  case "$LINE" in
    *"album"*) pass "有同专辑专题" ;;
    *) fail "缺同专辑专题：$LINE" ;;
  esac
  case "$LINE" in
    *"playlists=2"*) pass "首页读到 2 个歌单" ;;
    *) fail "歌单数不对：$LINE" ;;
  esac
else
  fail "40 秒内没有首页编排日志，见 $DIAG"
fi
sleep 2
xcrun simctl io "$DEVICE_ID" screenshot "$OUT/home-editorial.png" >/dev/null 2>&1 || true

if [ "$FAILS" = 0 ]; then
  echo "PASS 全部断言通过（规则自检 + 首页编排）"
  echo "     截图：$OUT/home-editorial.png"
  exit 0
fi
echo "FAIL $FAILS 项失败"
exit 1
