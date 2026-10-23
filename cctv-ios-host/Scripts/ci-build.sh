#!/bin/bash
# 直接调用 clang 构建 .app（不依赖 XcodeGen），用于 CI 与本地无工程文件场景
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${PY_DISABLE:-}" ] && { [ ! -s GeneratedJS/yangshipin.bundle.js ] || [ ! -s GeneratedJS/js-runtime.bundle.js ]; }; then
  npm ci --prefix JSPlugins --no-audit --no-fund
  npm run build --prefix JSPlugins
  npm test --prefix JSPlugins
fi
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "SDK: $SDK"
xcrun --sdk iphoneos clang --version | head -2

OUT="${CCTV_OUT:-build}"
APP="$OUT/CCTVHost.app"
rm -rf "$OUT"
mkdir -p "$APP"
cp Resources/Info.plist "$APP/Info.plist"
cp Resources/*.json "$APP/" 2>/dev/null || true
if [ -n "${PY_DISABLE:-}" ]; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.example.cctvhost.nopy' "$APP/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName CCTVHost 无PY' "$APP/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :CCTVHostBuildVariant string no-python' "$APP/Info.plist"
else
  /usr/libexec/PlistBuddy -c 'Add :CCTVHostBuildVariant string full' "$APP/Info.plist"
fi
if [ -n "${CCTV_BASELINE:-}" ]; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.example.cctvhost.baseline09.nopy' "$APP/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName CCTVHost 0.9对照' "$APP/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.9.0' "$APP/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CCTVHostBuildVariant baseline09' "$APP/Info.plist"
fi
ICON_PARTIAL="$OUT/assetcatalog-info.plist"
xcrun --sdk iphoneos actool --output-format human-readable-text --notices --warnings \
  --platform iphoneos --minimum-deployment-target 15.0 --target-device iphone --target-device ipad \
  --app-icon AppIcon --compress-pngs --compile "$APP" \
  --output-partial-info-plist "$ICON_PARTIAL" Resources/Assets.xcassets
python3 - "$APP/Info.plist" "$ICON_PARTIAL" <<'PY'
import plistlib,sys
base_path,icon_path=sys.argv[1:]
with open(base_path,'rb') as f: base=plistlib.load(f)
with open(icon_path,'rb') as f: icon=plistlib.load(f)
base.update(icon)
with open(base_path,'wb') as f: plistlib.dump(base,f,sort_keys=False)
assert 'CFBundleIcons' in base and 'CFBundlePrimaryIcon' in base['CFBundleIcons']
PY
[ -s "$APP/Assets.car" ] || { echo "::error::AppIcon asset catalog did not produce Assets.car"; exit 1; }
if [ -z "${PY_DISABLE:-}" ]; then cp Plugins/ysp-live.py "$APP/ysp-live.py"; cp Scripts/host_service_runtime.py "$APP/host_service_runtime.py"; cp Plugins/yangshipin-js.py "$APP/yangshipin-js.py"; cp GeneratedJS/* "$APP/"; mkdir -p "$APP/JSPlugins"; cp -R JSPlugins/yangshipin JSPlugins/compat "$APP/JSPlugins/"; cp JSPlugins/package.json JSPlugins/package-lock.json JSPlugins/build.mjs "$APP/JSPlugins/"; fi
if [ -z "${PY_DISABLE:-}" ]; then
  cp Plugins/media-service.py Plugins/host_media_runtime.py Plugins/host_media_relay.py Plugins/node-plugin-host.cjs "$APP/"
  cp -R Plugins/base "$APP/base"
  cp -R JSPlugins/generic JSPlugins/drpy "$APP/JSPlugins/"
  cp Resources/NodeMobile-LICENSE.txt "$APP/"
  python3 Scripts/prepare_node_runtime.py "$APP"
fi
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
  python3 -m pip install --disable-pip-version-check --no-compile --only-binary=:all: --platform any --implementation py --python-version 3.13 \
    --target "$APP/python/lib/python${PY_VER}/site-packages" -r Scripts/media-python-requirements.txt
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

SOURCES=$(find Sources -maxdepth 1 -name '*.m' -print | sort | tr '\n' ' ')

set -x
clang -arch arm64 \
  -isysroot "$SDK" \
  -miphoneos-version-min=15.0 \
  -fobjc-arc \
  -I Sources/Include \
  -F Frameworks \
  -framework JavaScriptCore -framework Security -framework Foundation -framework UIKit -framework ImageIO -framework CoreGraphics -framework CoreMedia -framework UniformTypeIdentifiers -framework QuartzCore \
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
