#!/bin/bash
set -euo pipefail
AWAKE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$AWAKE_ROOT"
AWAKE_SIGNED="${1:-unsigned}"
xcodegen generate --spec ios/project.yml
AWAKE_IOS_VERSION="$(awk '/MARKETING_VERSION:/ {print $2; exit}' ios/project.yml)"
AWAKE_ARCHIVE="$AWAKE_ROOT/dist-ios/Awake-$AWAKE_IOS_VERSION.xcarchive"
AWAKE_DERIVED="$AWAKE_ROOT/dist-ios/DeviceDerivedData"
mkdir -p "$AWAKE_ROOT/dist-ios"
if [[ "$AWAKE_SIGNED" == "signed" ]]; then
  xcodebuild -project ios/Awake.xcodeproj -scheme AwakeIOS -configuration Release -destination 'generic/platform=iOS' -derivedDataPath "$AWAKE_DERIVED" -archivePath "$AWAKE_ARCHIVE" -allowProvisioningUpdates DEVELOPMENT_TEAM="${AWAKE_IOS_TEAM:-M2H88Z5S5A}" archive
  python3 - "$AWAKE_ROOT/dist-ios/ExportOptions.plist" <<'PY'
import os,plistlib,sys
options={'method':os.environ.get('AWAKE_IOS_EXPORT_METHOD','debugging'),'teamID':os.environ.get('AWAKE_IOS_TEAM','M2H88Z5S5A'),'signingStyle':'automatic','destination':'export','stripSwiftSymbols':True}
with open(sys.argv[1],'wb') as f:plistlib.dump(options,f)
PY
  xcodebuild -exportArchive -archivePath "$AWAKE_ARCHIVE" -exportPath "$AWAKE_ROOT/dist-ios/Signed" -exportOptionsPlist "$AWAKE_ROOT/dist-ios/ExportOptions.plist" -allowProvisioningUpdates
else
  xcodebuild -project ios/Awake.xcodeproj -scheme AwakeIOS -configuration Release -destination 'generic/platform=iOS' -derivedDataPath "$AWAKE_DERIVED" -archivePath "$AWAKE_ARCHIVE" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO archive
  AWAKE_STAGE="$(mktemp -d "$AWAKE_ROOT/dist-ios/package.XXXXXX")"
  trap 'rm -rf "$AWAKE_STAGE"' EXIT
  mkdir -p "$AWAKE_STAGE/Payload"
  ditto "$AWAKE_ARCHIVE/Products/Applications/Awake.app" "$AWAKE_STAGE/Payload/Awake.app"
  ditto -c -k --keepParent "$AWAKE_STAGE/Payload" "$AWAKE_ROOT/dist-ios/Awake-$AWAKE_IOS_VERSION-ios-arm64-unsigned.ipa"
  shasum -a 256 "$AWAKE_ROOT/dist-ios/Awake-$AWAKE_IOS_VERSION-ios-arm64-unsigned.ipa" > "$AWAKE_ROOT/dist-ios/Awake-$AWAKE_IOS_VERSION-ios-arm64-unsigned.ipa.sha256"
  printf 'IPA: %s\n' "$AWAKE_ROOT/dist-ios/Awake-$AWAKE_IOS_VERSION-ios-arm64-unsigned.ipa"
fi
