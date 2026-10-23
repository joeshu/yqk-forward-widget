#!/bin/bash
# UI-only simulator target. Proprietary device playback frameworks are replaced
# by a test stub; this target makes no playback or DRM validation claims.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=ui-preview
APP="$OUT/CCTVHostUI.app"
mkdir -p "$APP"
python3 -u Tests/UISmoke/fixture_server.py "$OUT/fixture-port.txt" > "$OUT/fixture.log" 2>&1 &
FIXTURE_PID=$!
trap 'kill "$FIXTURE_PID" 2>/dev/null || true' EXIT
for attempt in $(seq 1 150); do
  if [ -s "$OUT/fixture-port.txt" ]; then break; fi
  if ! kill -0 "$FIXTURE_PID" 2>/dev/null; then cat "$OUT/fixture.log"; exit 1; fi
  sleep 0.2
done
if [ ! -s "$OUT/fixture-port.txt" ]; then cat "$OUT/fixture.log"; exit 1; fi
FIXTURE_PORT=$(cat "$OUT/fixture-port.txt")
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
ARCH=$(uname -m)
xcrun --sdk iphonesimulator clang -fobjc-arc -target "$ARCH-apple-ios15.0-simulator" -isysroot "$SDK" \
  -I Sources/Include -I Sources Sources/*.m Tests/UISmoke/*.m \
  -framework WebKit -framework JavaScriptCore -framework Security -framework Foundation -framework UIKit -framework ImageIO -framework CoreGraphics -framework CoreMedia -framework AVFoundation -framework AVKit \
  -framework MediaPlayer -framework QuartzCore -framework UniformTypeIdentifiers -lz \
  -o "$APP/CCTVHost"
cp Resources/channels.json "$APP/"
cp Plugins/node-plugin-host.cjs "$APP/"
python3 - "$APP/catpaw-ui.cjs" <<'PY'
import hashlib,pathlib,sys,urllib.request
url='https://joeshu.github.io/yqk-forward-widget/catpaw/index.js'
data=urllib.request.urlopen(url,timeout=30).read(8*1024*1024)
assert hashlib.sha256(data).hexdigest()=='51f535c2bf5e7dfdd2b7a6b941a2d9475e4010ab94bf08488542246eeebe344a','Catpaw fixture changed'
pathlib.Path(sys.argv[1]).write_bytes(data)
PY
python3 Scripts/prepare_node_runtime.py "$APP" --simulator
codesign --force --sign - "$APP/Frameworks/NodeMobile.framework"
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
xcrun simctl launch "$SIM" com.example.cctvhost.uismoke --smoke-port "$FIXTURE_PORT"
CONTAINER=$(xcrun simctl get_app_container "$SIM" com.example.cctvhost.uismoke data)
for attempt in $(seq 1 120); do
  if [ -f "$CONTAINER/Documents/ui-smoke/results.json" ]; then break; fi
  sleep 2
done
cp -R "$CONTAINER/Documents/ui-smoke/." "$OUT/"
if [ -f "$CONTAINER/Library/Application Support/ysp/cctvhost.log" ]; then
  cp "$CONTAINER/Library/Application Support/ysp/cctvhost.log" "$OUT/diagnostic.log"
fi
cat "$OUT/fixture.log"
python3 - "$OUT/results.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); print(json.dumps(r,ensure_ascii=False,indent=2)); assert r['passed'],r['failures']
PY
