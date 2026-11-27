#!/bin/bash
# Exercises the real embedded libmpv and Metal surface in an iOS simulator.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=mpv-preview
APP="$OUT/CCTVMPVSmoke.app"
mkdir -p "$APP"
python3 Scripts/prepare_mpv_runtime.py "$APP" --simulator
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun --sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator -isysroot "$SDK" -fobjc-arc \
  -I Sources -I Sources/Include \
  Tests/MPVSmoke/main.m Sources/MediaPlaybackMPVAdapter.m Sources/HostMPVLifecycle.c Sources/MediaPlaybackFullscreenHost.m \
  -framework Foundation -framework UIKit -framework QuartzCore -framework CoreMedia -framework AVFoundation -framework AVKit \
  -o "$APP/CCTVMPVSmoke" 2>&1 | tee "$OUT/compile.log"
python3 - "$APP" <<'PY'
import base64, pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
(app / 'fixture.mp4').write_bytes(base64.b64decode(pathlib.Path('Tests/UISmoke/video_fixture.b64').read_text()))
info = dict(CFBundleIdentifier='com.example.cctvhost.mpvsmoke', CFBundleExecutable='CCTVMPVSmoke',
            CFBundleName='CCTV MPV Smoke', CFBundlePackageType='APPL', CFBundleVersion='1',
            CFBundleShortVersionString='1.0', MinimumOSVersion='17.0', UIDeviceFamily=[1,2],
            UILaunchScreen={}, UISupportedInterfaceOrientations=['UIInterfaceOrientationPortrait',
                'UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight'])
(app / 'Info.plist').write_bytes(plistlib.dumps(info))
PY
codesign --force --sign - "$APP/Frameworks/CCTVMPVCore.framework"
codesign --force --sign - "$APP"
SIM=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(v["udid"] for k,vs in d["devices"].items() if "iOS" in k for v in vs if v["name"]=="iPhone 16"))')
xcrun simctl boot "$SIM" || true
xcrun simctl bootstatus "$SIM" -b
xcrun simctl uninstall "$SIM" com.example.cctvhost.mpvsmoke || true
xcrun simctl install "$SIM" "$APP"
xcrun simctl launch "$SIM" com.example.cctvhost.mpvsmoke
CONTAINER=$(xcrun simctl get_app_container "$SIM" com.example.cctvhost.mpvsmoke data)
RESULT="$CONTAINER/Documents/mpv-results.json"
for attempt in $(seq 1 200); do
  if [ -f "$CONTAINER/Documents/mpv-frame-ready" ]; then
    xcrun simctl io "$SIM" screenshot "$OUT/fullscreen.png"
    touch "$CONTAINER/Documents/mpv-frame-captured"
    break
  fi
  [ -f "$RESULT" ] && break
  sleep 0.2
done
for attempt in $(seq 1 45); do [ -f "$RESULT" ] && break; sleep 1; done
xcrun simctl spawn "$SIM" log show --last 5m --style compact --predicate 'process == "CCTVMPVSmoke"' > "$OUT/simulator.log" 2>&1 || true
if [ ! -f "$RESULT" ]; then echo '::error::MPV simulator smoke did not complete'; exit 1; fi
cp "$RESULT" "$OUT/results.json"
python3 - "$OUT/results.json" <<'PY'
import json,sys
result=json.load(open(sys.argv[1])); print(json.dumps(result,ensure_ascii=False,indent=2))
assert result['passed'] and result['rounds']==3,result
PY
swift Tests/MPVSmoke/validate-screenshot.swift "$OUT/fullscreen.png" | tee "$OUT/screenshot-check.log"
xcrun simctl terminate "$SIM" com.example.cctvhost.mpvsmoke || true
