#!/bin/bash
# Real embedded Zero/DEX/AVPlayer test. Cicada uses an explicitly controlled SDK fixture.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=jar-preview
APP="$OUT/CCTVJARSmoke.app"
RUNTIME="${CCTV_JAR_CACHE:-$PWD/.jar-runtime}/iphonesimulator"
mkdir -p "$APP"
cp -R "$RUNTIME/Resources/" "$APP/"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun clang -target arm64-apple-ios17.0-simulator -isysroot "$SDK" -fobjc-arc -DCCTV_JAR_ENABLED=1 \
  -I Sources -I Sources/Include -I "$RUNTIME/include" \
  Tests/JARSmoke/main.m Tests/JARSmoke/CicadaAdapterProbe.m Sources/MediaJARRuntime.m Sources/MediaPlaybackCicadaAdapter.m "$RUNTIME/AppleRuntime.m" \
  -Wl,-force_load,"$RUNTIME/lib/libTVAppleRuntime.a" -Wl,-export_dynamic \
  -lc++ -lz -liconv -framework Security -framework UIKit -framework Foundation -framework AVFoundation -framework CoreMedia -framework QuartzCore -framework CoreGraphics \
  -o "$APP/CCTVHost" 2>&1 | tee "$OUT/compile.log"
python3 - "$APP/Info.plist" <<'PY'
import plistlib,sys
p=dict(CFBundleIdentifier='com.example.cctvhost.jarsmoke',CFBundleExecutable='CCTVHost',CFBundleName='CCTV JAR Smoke',CFBundlePackageType='APPL',CFBundleVersion='1',CFBundleShortVersionString='1.0',MinimumOSVersion='17.0',UIDeviceFamily=[1,2],UILaunchScreen={},NSAppTransportSecurity={'NSAllowsLocalNetworking':True,'NSAllowsArbitraryLoads':True})
open(sys.argv[1],'wb').write(plistlib.dumps(p))
PY
codesign --force --sign - "$APP"
python3 -u Tests/JARSmoke/server.py "$OUT/port.txt" > "$OUT/server.log" 2>&1 &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null || true' EXIT
for attempt in $(seq 1 50); do [ -s "$OUT/port.txt" ] && break; sleep 0.1; done
PORT=$(cat "$OUT/port.txt")
SIM=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(v["udid"] for k,vs in d["devices"].items() if "iOS" in k for v in vs if v["name"].startswith("iPhone")))')
xcrun simctl boot "$SIM" || true
xcrun simctl bootstatus "$SIM" -b
xcrun simctl install "$SIM" "$APP"
xcrun simctl launch "$SIM" com.example.cctvhost.jarsmoke --port "$PORT"
CONTAINER=$(xcrun simctl get_app_container "$SIM" com.example.cctvhost.jarsmoke data)
RESULT="$CONTAINER/Documents/jar-results.json"
for attempt in $(seq 1 180); do [ -f "$RESULT" ] && break; sleep 2; done
cp "$CONTAINER/Library/Caches/embedded-jvm.log" "$OUT/embedded-jvm.log" 2>/dev/null || true
if [ ! -f "$RESULT" ]; then echo '::error::Embedded JVM/DEX smoke did not complete'; tail -100 "$OUT/embedded-jvm.log"; exit 1; fi
cp "$RESULT" "$OUT/results.json"
python3 - "$OUT/results.json" "$OUT/server.log" <<'PY'
import json,sys
result=json.load(open(sys.argv[1]));print(json.dumps(result,ensure_ascii=False,indent=2));assert result['passed'],result
rows=[json.loads(line) for line in open(sys.argv[2]) if line.startswith('{')]
assert sum(r['path']=='/fixture.jar' for r in rows)==1,'JAR download was not shared across operations'
assert any(r['path']=='/video.mp4' and r['media_header'] and not r['jar_header'] for r in rows),'Media header propagation failed'
PY
xcrun simctl terminate "$SIM" com.example.cctvhost.jarsmoke || true
