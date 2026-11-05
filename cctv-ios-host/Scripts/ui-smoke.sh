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
SMOKE_LAUNCH_EPOCH=$(date +%s)
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
ARCH=$(uname -m)
xcrun --sdk iphonesimulator clang -fobjc-arc -target "$ARCH-apple-ios15.0-simulator" -isysroot "$SDK" \
  -I Sources/Include -I Sources Sources/*.m Tests/UISmoke/*.m \
  -framework WebKit -framework JavaScriptCore -framework Security -framework Foundation -framework UIKit -framework ImageIO -framework CoreGraphics -framework CoreMedia -framework AVFoundation -framework AVKit \
  -framework MediaPlayer -framework QuartzCore -framework UniformTypeIdentifiers -framework MetricKit -lz \
  -o "$APP/CCTVHost" 2>&1 | tee "$OUT/compile.log"
cp Resources/channels.json "$APP/"
cp Plugins/node-plugin-host.cjs "$APP/"
if [ ! -s GeneratedJS/node-fetch.bundle.cjs ]; then
  npm ci --prefix JSPlugins --no-audit --no-fund
  npm run build --prefix JSPlugins
fi
cp GeneratedJS/node-fetch.bundle.cjs "$APP/"
npm ci --prefix ../catpaw --ignore-scripts --no-audit --no-fund
npm run build --prefix ../catpaw
python3 - "$APP/catpaw-ui.cjs" ../catpaw/dist/index.js ../catpaw/dist/index.js.md5 <<'PY'
import hashlib,pathlib,sys
source=pathlib.Path(sys.argv[2]);expected=pathlib.Path(sys.argv[3]).read_text().strip()
data=source.read_bytes()
assert hashlib.md5(data).hexdigest()==expected,'local CatPaw bundle checksum mismatch'
pathlib.Path(sys.argv[1]).write_bytes(data)
print('Using repository-pinned CatPaw bundle sha256='+hashlib.sha256(data).hexdigest())
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
APP_LAUNCH=$(xcrun simctl launch "$SIM" com.example.cctvhost.uismoke --smoke-port "$FIXTURE_PORT")
echo "$APP_LAUNCH"
SMOKE_APP_PID=$(printf '%s\n' "$APP_LAUNCH" | sed -nE 's/.*: ([0-9]+)$/\1/p' | tail -n 1)
CONTAINER=$(xcrun simctl get_app_container "$SIM" com.example.cctvhost.uismoke data)
PROGRESS_FILE="$CONTAINER/Documents/ui-smoke/smoke-progress.json"
SMOKE_WAIT_STARTED=$(date +%s)
for attempt in $(seq 1 255); do
  if [ -f "$CONTAINER/Documents/ui-smoke/results.json" ]; then break; fi
  sleep 2
  if (( attempt % 15 == 0 )); then
    now=$(date +%s)
    last_progress=$(python3 - "$PROGRESS_FILE" "$SMOKE_WAIT_STARTED" <<'PY'
import os,sys
path=sys.argv[1]
print(int(os.path.getmtime(path)) if os.path.isfile(path) else int(sys.argv[2]))
PY
)
    stalled_for=$((now-last_progress))
    if (( stalled_for >= 120 )); then
      echo "::error::UI smoke stopped advancing for ${stalled_for}s"
      if [ -f "$PROGRESS_FILE" ]; then cat "$PROGRESS_FILE"; fi
      if [[ "$SMOKE_APP_PID" =~ ^[0-9]+$ ]]; then
        ps -p "$SMOKE_APP_PID" -o pid=,stat=,comm= || echo "Simulator app PID $SMOKE_APP_PID is no longer alive"
        if command -v sample >/dev/null 2>&1; then
          sample "$SMOKE_APP_PID" 5 -file "$OUT/ui-main-thread-sample.txt" || echo "sample could not attach to simulator PID $SMOKE_APP_PID"
          if [ -s "$OUT/ui-main-thread-sample.txt" ]; then sed -n '1,240p' "$OUT/ui-main-thread-sample.txt"; fi
        else
          echo "macOS sample utility is unavailable; collecting simulator crash reports instead"
        fi
      fi
      xcrun simctl spawn "$SIM" log show --last 5m --style compact --predicate 'process == "CCTVHostUI" OR process == "CCTVHost"' > "$OUT/ui-simulator-console.log" 2>&1 || true
      if [ -s "$OUT/ui-simulator-console.log" ]; then tail -n 160 "$OUT/ui-simulator-console.log"; fi
      python3 - "$SMOKE_LAUNCH_EPOCH" "$OUT" <<'PY'
import json
import pathlib
import shutil
import sys

started = int(sys.argv[1])
output = pathlib.Path(sys.argv[2])
roots = [pathlib.Path.home() / "Library/Logs/DiagnosticReports"]
reports = []
for root in roots:
    if root.exists():
        reports.extend(path for path in root.rglob("*")
                       if path.is_file() and path.suffix.lower() in {".ips", ".crash", ".hang"}
                       and "cctvhost" in path.name.lower()
                       and path.stat().st_mtime >= started - 10)
for report in sorted(set(reports), key=lambda path: path.stat().st_mtime):
    target = output / report.name
    shutil.copy2(report, target)
    print(f"Captured simulator crash report: {target}")
    if report.suffix.lower() == ".ips":
        try:
            content = report.read_text(errors="replace")
            payload = json.loads(content[content.index("\n") + 1:])
            print("Crash summary:", json.dumps({"exception": payload.get("exception"),
                  "faultingThread": payload.get("faultingThread"), "threads": payload.get("threads", [])},
                  ensure_ascii=False)[:24000])
        except Exception as error:
            print(f"Could not summarize crash report {report.name}: {type(error).__name__}")
if not reports:
    print("No new CCTVHost simulator crash report was found")
PY
      break
    fi
  fi
done
if [ -d "$CONTAINER/Documents/ui-smoke" ]; then
  cp -R "$CONTAINER/Documents/ui-smoke/." "$OUT/"
else
  echo "::warning::UI smoke produced no output directory in the simulator container; the app may have crashed or hung at startup"
fi
if [ -f "$CONTAINER/Library/Application Support/ysp/cctvhost.log" ]; then
  cp "$CONTAINER/Library/Application Support/ysp/cctvhost.log" "$OUT/diagnostic.log"
fi
if [ -f "$CONTAINER/Library/Application Support/ysp/diagnostics/runtime-debug.jsonl" ]; then
  cp "$CONTAINER/Library/Application Support/ysp/diagnostics/runtime-debug.jsonl" "$OUT/runtime-debug.jsonl"
fi
# Best-effort simulator diagnostics: app console output and crash reports, so a
# silent smoke run still leaves evidence instead of an empty artifact.
xcrun simctl spawn "$SIM" log show --predicate 'processImagePath CONTAINS "CCTVHost"' --style syslog --last 15m > "$OUT/simulator.log" 2>&1 || true
for crash in ~/Library/Logs/DiagnosticReports/*CCTVHost*.ips; do
  [ -f "$crash" ] && cp "$crash" "$OUT/crash-$(basename "$crash" .ips).log" 2>/dev/null || true
done
cat "$OUT/fixture.log"
if [ ! -f "$OUT/results.json" ]; then
  echo "::error::UI smoke did not finish; last checkpoint follows"
  if [ -f "$OUT/smoke-progress.json" ]; then cat "$OUT/smoke-progress.json"; fi
  for diagnostic in "$OUT/ui-main-thread-sample.txt" "$OUT/ui-simulator-console.log"; do
    if [ -s "$diagnostic" ]; then echo "::group::$(basename "$diagnostic")"; tail -n 240 "$diagnostic"; echo "::endgroup::"; fi
  done
  exit 1
fi
if [ -f "$OUT/runtime-debug.jsonl" ]; then
  grep -E '"event":"(media_home_request_started|media_home_response_received|media_home_response_discarded|media_api_failed|media_api_succeeded|media_service_health_failed|media_capabilities_readable)"' "$OUT/runtime-debug.jsonl" | tail -100 || true
fi
python3 - "$OUT/results.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); print(json.dumps(r,ensure_ascii=False,indent=2)); assert r['passed'],r['failures']
PY
