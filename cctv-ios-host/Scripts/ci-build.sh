#!/bin/bash
# 直接调用 clang 构建 .app（不依赖 XcodeGen），用于 CI 与本地无工程文件场景
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "SDK: $SDK"
xcrun --sdk iphoneos clang --version | head -2

OUT=build
APP="$OUT/CCTVHost.app"
rm -rf "$OUT"
mkdir -p "$APP"
cp Resources/Info.plist "$APP/Info.plist"
cp Resources/*.json "$APP/" 2>/dev/null || true
cp Plugins/ysp-live.py "$APP/ysp-live.py"
printf 'APPL????' > "$APP/PkgInfo"
mkdir -p "$APP/Frameworks"

# --- 内置 CPython（Python-Apple-support） ---
PY_VER=3.13
PY_TGZ=/tmp/python-ios.tar.gz
if [ ! -f "$PY_TGZ" ]; then
  curl -sSL -o "$PY_TGZ" "https://github.com/beeware/Python-Apple-support/releases/download/3.13-b16/Python-${PY_VER}-iOS-support.b16.tar.gz"
fi
rm -rf /tmp/pyroot && mkdir -p /tmp/pyroot && tar -xzf "$PY_TGZ" -C /tmp/pyroot
echo "--- pyroot top ---"; ls /tmp/pyroot | head

mkdir -p "$APP/python/lib"
{ [ -n "${PY_DISABLE:-}" ] || cp -R /tmp/pyroot/Python.xcframework/lib/python3.13 "$APP/python/lib/"; }
rm -rf "$APP/python/lib/python3.13/test" "$APP/python/lib/python3.13/idlelib" \
       "$APP/python/lib/python3.13/tkinter" "$APP/python/lib/python3.13/ensurepip" \
       "$APP/python/lib/python3.13/turtledemo" "$APP/python/lib/python3.13/distutils"
find "$APP/python" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$APP/python" -name '*.pyc' -delete 2>/dev/null || true
PY_INC="$(dirname "$(find /tmp/pyroot -path '*ios-arm64*' -name 'Python.h' | head -1)")"
if [ ! -f "$PY_INC/Python.h" ]; then
  echo "::warning title=pyinc::Python.h not found, building without embedded Python"
  PY_DISABLE=1
fi
echo "::notice title=pyinc::${PY_INC:-none}"; 
echo "PY_INC=$PY_INC"
PY_LIB="$(find /tmp/pyroot -path '*ios-arm64*' -name 'Python.framework' -type d | head -1)"
if [ -z "$PY_LIB" ]; then
  echo "::warning title=pylib::Python.framework not found, building without embedded Python"
  PY_DISABLE=1
fi
echo "::notice title=pylib::${PY_LIB:-none}"
{ [ -n "${PY_DISABLE:-}" ] || cp -R "$PY_LIB" "$APP/Frameworks/"; }
for f in Frameworks/*.framework; do
  cp -R "$f" "$APP/Frameworks/"
done

SOURCES="Sources/main.m Sources/AppDelegate.m Sources/RootViewController.m Sources/EPGViewController.m Sources/M3UParser.m Sources/PyHost.m"

set -x
clang -arch arm64 \
  -isysroot "$SDK" \
  -miphoneos-version-min=15.0 \
  -fobjc-arc \
  -I Sources/Include \
  -F Frameworks \
  -framework Foundation -framework UIKit \
  -framework CNPlayerSDK -framework CicadaPlayerSDK -framework alivcffmpeg -framework AVFoundation -framework MediaPlayer -framework AVKit \
  $( [ -z "${PY_DISABLE:-}" ] && echo "-F $APP/Frameworks -framework Python -I $PY_INC" ) \
  -lz -lsqlite3 -lbz2 -liconv -lc++ \
  -Wl,-rpath,@executable_path/Frameworks \
  -Wl,-undefined,dynamic_lookup \
  -ObjC -lresolv \
  $SOURCES \
  -o "$APP/CCTVHost"
set +x

file "$APP/CCTVHost"
otool -L "$APP/CCTVHost" | head -12

mkdir -p "$OUT/Payload"
cp -R "$APP" "$OUT/Payload/"
cd "$OUT"
zip -qry CCTVHost-unsigned.ipa Payload
unzip -l CCTVHost-unsigned.ipa | head -12
shasum -a 256 CCTVHost-unsigned.ipa | tee CCTVHost-unsigned.ipa.sha256
