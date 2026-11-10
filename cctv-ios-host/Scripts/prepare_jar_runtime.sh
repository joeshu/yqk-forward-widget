#!/bin/bash
# Build a pinned, interpreter-only runtime from corresponding source.
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET="${1:-ios}"
case "$TARGET" in ios) PLATFORM=iphoneos;; ios-simulator) PLATFORM=iphonesimulator;; *) exit 2;; esac
[ "$(uname -s)-$(uname -m)" = Darwin-arm64 ] || { echo 'JAR runtime requires an Apple silicon Mac build host' >&2; exit 1; }
ROOT="$PWD"
CACHE="${CCTV_JAR_CACHE:-$ROOT/.jar-runtime}"
REV=$(python3 -c 'import json; print(json.load(open("Runtime/JAR/upstream.json"))["revision"])')
SHA=$(python3 -c 'import json; print(json.load(open("Runtime/JAR/upstream.json"))["archive_sha256"])')
SOURCE="$CACHE/source-$REV"
OUT="$CACHE/$PLATFORM"
# A packaged runtime is reusable only for this source revision and SDK.
PROFILE=$(cat "$ROOT/Scripts/prepare_jar_runtime.sh" "$ROOT/Scripts/optimize_jar_runtime.py" | shasum -a 256 | cut -d' ' -f1)
NATIVE_STAMP="$REV-$(xcrun --sdk "$PLATFORM" --show-sdk-version)-2"
STAMP="$NATIVE_STAMP-$PROFILE"
if [ -f "$OUT/complete" ] && [ "$(cat "$OUT/complete")" = "$STAMP" ] && [ -s "$OUT/lib/libTVAppleRuntime.a" ] && [ -s "$OUT/packaging-report.json" ]; then
  echo "Using verified JAR runtime: $PLATFORM"; exit 0
fi
# A prefix cache restore may come from another SDK. Do not reuse that native build.
if [ -f "$OUT/complete" ]; then
  case "$(cat "$OUT/complete")" in
    "$NATIVE_STAMP"|"$NATIVE_STAMP"-*) ;;
    *) rm -rf "$SOURCE/build/apple-runtime" ;;
  esac
fi
mkdir -p "$CACHE"
if [ ! -f "$SOURCE/.verified" ]; then
  curl -fL --retry 2 "https://codeload.github.com/jo32/tvbox-silicon/tar.gz/$REV" -o "$CACHE/source.tar.gz.tmp"
  echo "$SHA  $CACHE/source.tar.gz.tmp" | shasum -a 256 -c -
  mkdir -p "$SOURCE"
  tar -xzf "$CACHE/source.tar.gz.tmp" --strip-components=1 -C "$SOURCE"
  touch "$SOURCE/.verified"
  rm "$CACHE/source.tar.gz.tmp"
fi
cd "$SOURCE"
export JAVA_HOME="${JAVA_HOME:-$(/usr/libexec/java_home -v 17)}"
# JavaHost's bytecode targets Java 17; the native Zero build downloads its own pinned boot JDK.
Scripts/build-java-host.sh
python3 "$ROOT/Scripts/optimize_jar_runtime.py" configure Scripts/package-apple-runtime.sh
Scripts/package-apple-runtime.sh "$TARGET"
rm -rf "$OUT"
cp -R "build/AppleRuntime/$PLATFORM" "$OUT"
cp Runtime/AppleRuntime/Native/AppleRuntime.m "$OUT/AppleRuntime.m"
cp "$ROOT/Runtime/JAR/upstream.json" "$OUT/Resources/jar-runtime.json"
cp -R "$ROOT/Runtime/JAR" "$OUT/Resources/JARLicenses"
python3 "$ROOT/Scripts/optimize_jar_runtime.py" resources "$OUT" \
  --baseline-modules "$SOURCE/build/apple-runtime/jlink-$TARGET/image-baseline/lib/modules" \
  --jimage "$SOURCE/build/apple-runtime/openjdk-mobile/build/macosx-host/images/jdk/bin/jimage"
printf '%s\n' "$STAMP" > "$OUT/complete"
echo "Prepared JAR runtime: $OUT"
