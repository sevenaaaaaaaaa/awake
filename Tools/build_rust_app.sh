#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
npm run build --prefix ui

# 默认构建 macOS 通用二进制（Intel + Apple Silicon）。
# 只想要单架构时可用 AWAKE_ARCHS=arm64 或 AWAKE_ARCHS=x86_64。
ARCHS="${AWAKE_ARCHS:-arm64 x86_64}"
BINARIES=()

# 通用包需要两个架构的标准库。Homebrew 的 rustc 只带宿主架构，
# 有 rustup 时统一走 rustup 的 stable 工具链（通常已安装 x86_64 目标）。
run_cargo() {
  # 必须显式指定 RUSTC：cargo 默认从 PATH 找 rustc，
  # 在 Homebrew rust + rustup 并存的机器上会拿到没有 x86 标准库的宿主 rustc。
  if command -v rustup >/dev/null 2>&1; then
    local cargo_bin rustc_bin rustdoc_bin
    cargo_bin="$(rustup which --toolchain stable cargo 2>/dev/null || true)"
    rustc_bin="$(rustup which --toolchain stable rustc 2>/dev/null || true)"
    rustdoc_bin="$(rustup which --toolchain stable rustdoc 2>/dev/null || true)"
    if [[ -n "$cargo_bin" && -n "$rustc_bin" ]]; then
      RUSTC="$rustc_bin" RUSTDOC="$rustdoc_bin" RUSTUP_TOOLCHAIN=stable "$cargo_bin" "$@"
      return
    fi
  fi
  cargo "$@"
}

APP_PATH="$PROJECT_ROOT/dist-rust/Awake.app"
APP_BINARY="$APP_PATH/Contents/MacOS/Awake"

# 覆盖一个正在运行的 Mach-O 会被系统拦下：lipo 直接 Killed: 9，cp 之后
# 写 Info.plist 与 codesign 这两步就永远到不了，包里的版本与签名停在上一版，
# 而日志里只有一句「Killed: 9」。所以先查实例，再动包。
if lsof -- "$APP_BINARY" >/dev/null 2>&1; then
  echo "有一个正在运行的 Awake 实例，先退出它再构建：" >&2
  pgrep -fl 'Awake.app/Contents/MacOS/Awake' >&2
  echo "覆盖运行中的可执行文件会让 Info.plist 与签名停在旧值。" >&2
  exit 1
fi

for arch in $ARCHS; do
  case "$arch" in
    arm64) triple="aarch64-apple-darwin" ;;
    x86_64) triple="x86_64-apple-darwin" ;;
    *)
      echo "不支持的架构：$arch" >&2
      exit 1
      ;;
  esac
  echo "Building awake-app for $triple ..."
  run_cargo build --manifest-path rust/Cargo.toml -p awake-app --release --target "$triple"
  BINARIES+=("$PROJECT_ROOT/rust/target/$triple/release/awake-app")
done

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

# 先在构建产物上验架构，再往包里放。读包内的可执行文件容易碰上正在运行的实例，
# 而这一步要证明的本来就是「各架构都编出来了」，在源文件上验同样成立且更稳。
index=0
for arch in $ARCHS; do
  lipo -verify_arch "$arch" "${BINARIES[$index]}"
  index=$((index + 1))
done

if [[ "${#BINARIES[@]}" -eq 1 ]]; then
  cp "${BINARIES[0]}" "$APP_BINARY"
else
  lipo -create -output "$APP_BINARY" "${BINARIES[@]}"
fi

cp Resources/Awake.icns "$APP_PATH/Contents/Resources/Awake.icns"
python3 - "$PROJECT_ROOT" <<'PY'
import json,pathlib,plistlib,sys
root=pathlib.Path(sys.argv[1])
version=json.loads((root/'ui/package.json').read_text())['version']
info={
 'CFBundleDisplayName':'Awake','CFBundleExecutable':'Awake','CFBundleIconFile':'Awake',
 'CFBundleIdentifier':'com.seven.awake','CFBundleInfoDictionaryVersion':'6.0',
 'CFBundleName':'Awake','CFBundlePackageType':'APPL','CFBundleShortVersionString':version,
 'CFBundleVersion':version,'LSApplicationCategoryType':'public.app-category.music',
 'LSMinimumSystemVersion':'14.0','NSHighResolutionCapable':True,'NSPrincipalClass':'NSApplication'
}
with (root/'dist-rust/Awake.app/Contents/Info.plist').open('wb') as f: plistlib.dump(info,f)
PY
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
printf 'Built: %s (%s)\n' "$APP_PATH" "$(lipo -archs "$APP_BINARY")"
