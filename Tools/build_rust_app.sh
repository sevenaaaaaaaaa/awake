#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
npm run build --prefix ui
cargo build --manifest-path rust/Cargo.toml -p awake-app --release
APP_PATH="$PROJECT_ROOT/dist-rust/Awake.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp rust/target/release/awake-app "$APP_PATH/Contents/MacOS/Awake"
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
printf 'Built: %s\n' "$APP_PATH"
