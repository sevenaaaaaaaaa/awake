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

APP_PATH="$PROJECT_ROOT/dist-rust/Awake.app"
APP_BINARY="$APP_PATH/Contents/MacOS/Awake"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
if [[ "${#BINARIES[@]}" -eq 1 ]]; then
  cp "${BINARIES[0]}" "$APP_BINARY"
else
  lipo -create -output "$APP_BINARY" "${BINARIES[@]}"
fi
lipo -info "$APP_BINARY"
for arch in $ARCHS; do
  case "$arch" in
    arm64) lipo -verify_arch arm64 "$APP_BINARY" ;;
    x86_64) lipo -verify_arch x86_64 "$APP_BINARY" ;;
  esac
done

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
