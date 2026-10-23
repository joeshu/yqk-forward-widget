#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=pre-epg-preview
APP="$OUT/Reference.app"
mkdir -p "$APP"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
ARCH=$(uname -m)
xcrun --sdk iphonesimulator clang -fobjc-arc -target "$ARCH-apple-ios15.0-simulator" -isysroot "$SDK" \
  -I Sources/Include -I Sources Sources/AppDelegate.m Sources/RootViewController.m Sources/main.m \
  Tests/UISmoke/SDKStub.m Tests/PreEPG/SmokeDriver.m \
  -framework Foundation -framework UIKit -framework QuartzCore -framework AVFoundation -o "$APP/CCTVHost"
cp Resources/channels.json "$APP/"
python3 - "$APP/Info.plist" <<'PY'
import plistlib,sys
p=plistlib.load(open('Resources/Info.plist','rb'))
p.update(CFBundleIdentifier='com.example.cctvhost.preepg.smoke',CFBundleSupportedPlatforms=['iPhoneSimulator'],MinimumOSVersion='15.0')
p.pop('UIRequiredDeviceCapabilities',None)
plistlib.dump(p,open(sys.argv[1],'wb'))
PY
codesign --force --sign - "$APP"
SIM=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(v["udid"] for k,vs in d["devices"].items() if "iOS" in k for v in vs if v["name"].startswith("iPhone")))')
xcrun simctl boot "$SIM" || true
xcrun simctl bootstatus "$SIM" -b
xcrun simctl install "$SIM" "$APP"
xcrun simctl launch "$SIM" com.example.cctvhost.preepg.smoke
CONTAINER=$(xcrun simctl get_app_container "$SIM" com.example.cctvhost.preepg.smoke data)
for attempt in $(seq 1 60); do
  if [ -f "$CONTAINER/Documents/pre-epg-smoke/results.json" ]; then break; fi
  sleep 2
done
cp -R "$CONTAINER/Documents/pre-epg-smoke/." "$OUT/"
python3 - "$OUT/results.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]));print(json.dumps(r,ensure_ascii=False));assert r['passed'],r['failures']
PY
