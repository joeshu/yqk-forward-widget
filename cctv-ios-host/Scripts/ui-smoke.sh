#!/bin/bash
# UI-only simulator target. Proprietary device playback frameworks are replaced
# by a test stub; this target makes no playback or DRM validation claims.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=ui-preview
APP="$OUT/CCTVHostUI.app"
mkdir -p "$APP"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
ARCH=$(uname -m)
xcrun --sdk iphonesimulator clang -fobjc-arc -target "$ARCH-apple-ios15.0-simulator" -isysroot "$SDK" \
  -I Sources/Include -I Sources Sources/*.m Tests/UISmoke/*.m \
  -framework Foundation -framework UIKit -framework CoreGraphics -framework CoreMedia -framework AVFoundation -framework AVKit \
  -framework MediaPlayer -framework QuartzCore -framework UniformTypeIdentifiers \
  -o "$APP/CCTVHost"
cp Resources/channels.json "$APP/"
python3 - "$APP/Info.plist" <<'PY'
import plistlib,sys
with open('Resources/Info.plist','rb') as f:p=plistlib.load(f)
p.update(CFBundleIdentifier='com.example.cctvhost.uismoke',CFBundleSupportedPlatforms=['iPhoneSimulator'],MinimumOSVersion='15.0')
p.pop('UIRequiredDeviceCapabilities',None)
with open(sys.argv[1],'wb') as f:plistlib.dump(p,f)
PY
codesign --force --sign - "$APP"
SIM=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(v["udid"] for k,vs in d["devices"].items() if "iOS" in k for v in vs if v["name"].startswith("iPhone")))')
xcrun simctl boot "$SIM" || true
xcrun simctl bootstatus "$SIM" -b
xcrun simctl install "$SIM" "$APP"
python3 Tests/UISmoke/fixture_server.py "$OUT/fixture-port.txt" &
FIXTURE_PID=$!
trap 'kill "$FIXTURE_PID" 2>/dev/null || true' EXIT
for attempt in $(seq 1 20); do
  if [ -s "$OUT/fixture-port.txt" ]; then break; fi
  sleep 0.2
done
FIXTURE_PORT=$(cat "$OUT/fixture-port.txt")
xcrun simctl launch "$SIM" com.example.cctvhost.uismoke --smoke-port "$FIXTURE_PORT"
CONTAINER=$(xcrun simctl get_app_container "$SIM" com.example.cctvhost.uismoke data)
for attempt in $(seq 1 40); do
  if [ -f "$CONTAINER/Documents/ui-smoke/results.json" ]; then break; fi
  sleep 2
done
cp -R "$CONTAINER/Documents/ui-smoke/." "$OUT/"
python3 - "$OUT/results.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); print(json.dumps(r,ensure_ascii=False,indent=2)); assert r['passed'],r['failures']
PY
