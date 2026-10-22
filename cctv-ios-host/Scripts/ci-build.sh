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
printf 'APPL????' > "$APP/PkgInfo"
mkdir -p "$APP/Frameworks"
for f in Frameworks/*.framework; do
  cp -R "$f" "$APP/Frameworks/"
done

SOURCES="Sources/main.m Sources/AppDelegate.m Sources/RootViewController.m"

set -x
clang -arch arm64 \
  -isysroot "$SDK" \
  -miphoneos-version-min=15.0 \
  -fobjc-arc \
  -I Sources/Include \
  -F Frameworks \
  -framework Foundation -framework UIKit \
  -framework CNPlayerSDK -framework CicadaPlayerSDK -framework alivcffmpeg \
  -Wl,-rpath,@executable_path/Frameworks \
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
