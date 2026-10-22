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

# --- 内置 CPython（Python-Apple-support device slice） ---
PY_VER=3.13
PY_TGZ=/tmp/python-ios.tar.gz
if [ -z "${PY_DISABLE:-}" ]; then
  if [ ! -s "$PY_TGZ" ]; then
    curl --fail --location --silent --show-error -o "$PY_TGZ" "https://github.com/beeware/Python-Apple-support/releases/download/3.13-b16/Python-${PY_VER}-iOS-support.b16.tar.gz"
  fi
  rm -rf /tmp/pyroot && mkdir -p /tmp/pyroot
  tar -xzf "$PY_TGZ" -C /tmp/pyroot
  PY_ROOT=/tmp/pyroot/Python.xcframework
  PY_INC="$PY_ROOT/ios-arm64/include/python3.13"
  PY_LIB="$PY_ROOT/ios-arm64/Python.framework"
  DEVICE_LIB="$PY_ROOT/ios-arm64/lib-arm64/python3.13"
  STDLIB="$PY_ROOT/lib/python3.13"
  DYNLOAD="$DEVICE_LIB/lib-dynload"
  for required in "$PY_INC/Python.h" "$PY_LIB/Python" "$STDLIB" "$DYNLOAD"; do
    if [ ! -e "$required" ]; then echo "::error::Required iOS CPython runtime item missing: $required"; exit 1; fi
  done
  for module in _ssl _socket _hashlib select _struct; do
    if ! compgen -G "$DYNLOAD/${module}.*.so" >/dev/null; then echo "::error::Missing iOS device Python extension: $module"; exit 1; fi
  done
  mkdir -p "$APP/python/lib/python${PY_VER}" "$APP/python/ssl"
  cp -R "$STDLIB/" "$APP/python/lib/python${PY_VER}/"
  cp -R "$DEVICE_LIB/" "$APP/python/lib/python${PY_VER}/"
  rm -rf "$APP/python/lib/python${PY_VER}/test" "$APP/python/lib/python${PY_VER}/idlelib" \
         "$APP/python/lib/python${PY_VER}/tkinter" "$APP/python/lib/python${PY_VER}/ensurepip" \
         "$APP/python/lib/python${PY_VER}/turtledemo" "$APP/python/lib/python${PY_VER}/distutils"
  rm -rf "$APP/python/lib/python${PY_VER}/__pycache__"
  find "$APP/python/lib/python${PY_VER}" -name '*.pyc' -delete
  for extension in "$APP/python/lib/python${PY_VER}/lib-dynload"/*.so; do
    [ -f "$extension" ] || continue
    filename=$(basename "$extension"); module=${filename%%.*}; framework="$APP/Frameworks/${module}.framework"
    mkdir -p "$framework"
    cp "$extension" "$framework/$module"
    cat > "$framework/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>$module</string><key>CFBundleIdentifier</key><string>org.python.extension.$module</string><key>CFBundlePackageType</key><string>FMWK</string></dict></plist>
PLIST
    printf 'Frameworks/%s.framework/%s\n' "$module" "$module" > "${extension%.so}.fwork"
    rm "$extension"
  done
  if [ ! -s /etc/ssl/cert.pem ]; then echo "::error::macOS CA bundle /etc/ssl/cert.pem missing; refusing to package TLS runtime"; exit 1; fi
  cp /etc/ssl/cert.pem "$APP/python/ssl/cert.pem"
  python3 Scripts/python_bootstrap.py --validate "$APP/python" --version "$PY_VER"
  cp -R "$PY_LIB" "$APP/Frameworks/"
else
  echo "::warning::PY_DISABLE requested; producing runtime-disabled build (plugin start reports error)"
fi
for f in Frameworks/*.framework; do
  cp -R "$f" "$APP/Frameworks/"
done

SOURCES="Sources/main.m Sources/AppDelegate.m Sources/RootViewController.m Sources/EPGViewController.m Sources/M3UParser.m Sources/PyHost.m Sources/PluginViewController.m Sources/SettingsViewController.m"

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
