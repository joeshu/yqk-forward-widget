#!/bin/bash
# Build a pinned, interpreter-only runtime from corresponding source.
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET="${1:-ios}"
case "$TARGET" in ios) PLATFORM=iphoneos; CONF=ios-aarch64-zero-release;; ios-simulator) PLATFORM=iphonesimulator; CONF=ios-aarch64-zero-simulator;; *) exit 2;; esac
[ "$(uname -s)-$(uname -m)" = Darwin-arm64 ] || { echo 'JAR runtime requires an Apple silicon Mac build host' >&2; exit 1; }
ROOT="$PWD"
CACHE="${CCTV_JAR_CACHE:-$ROOT/.jar-runtime}"
REV=$(python3 -c 'import json; print(json.load(open("Runtime/JAR/upstream.json"))["revision"])')
SHA=$(python3 -c 'import json; print(json.load(open("Runtime/JAR/upstream.json"))["archive_sha256"])')
SOURCE="$CACHE/source-$REV"
OUT="$CACHE/$PLATFORM"
# A packaged runtime is reusable only for this source revision and SDK.
PROFILE=$(cat "$ROOT/Scripts/prepare_jar_runtime.sh" "$ROOT/Scripts/optimize_jar_runtime.py" "$ROOT/Scripts/check_jar_compatibility.py" | shasum -a 256 | cut -d' ' -f1)
NATIVE_STAMP="$REV-$(xcrun --sdk "$PLATFORM" --show-sdk-version)-2"
STAMP="$NATIVE_STAMP-$PROFILE"
if [ -f "$OUT/complete" ] && [ "$(cat "$OUT/complete")" = "$STAMP" ] && [ -s "$OUT/lib/libTVAppleRuntime.a" ] && [ -s "$OUT/packaging-report.json" ] && { [ "$TARGET" != ios ] || [ -s "$OUT/compatibility/summary.json" ]; }; then
  echo "Using verified JAR runtime: $PLATFORM"
  cat "$OUT/packaging-report.json"
  if [ "$TARGET" = ios ]; then cat "$OUT/compatibility/summary.json"; fi
  exit 0
fi
# A prefix cache restore may come from another SDK. Do not reuse that native build.
if [ -f "$OUT/complete" ]; then
  case "$(cat "$OUT/complete")" in
    "$NATIVE_STAMP"|"$NATIVE_STAMP"-*) ;;
    *) rm -rf "$SOURCE/build/apple-runtime" ;;
  esac
fi
# Resource-only changes can reuse the signed-target native engine and matching
# jlink kit. Never infer this from a broad cache-key match alone.
native_cache_ready() {
  [ -f "$OUT/complete" ] || return 1
  case "$(cat "$OUT/complete")" in "$NATIVE_STAMP"|"$NATIVE_STAMP"-*) ;; *) return 1;; esac
  local work="$SOURCE/build/apple-runtime" base="$SOURCE/build/AppleRuntime/$PLATFORM"
  [ -s "$OUT/lib/libTVAppleRuntime.a" ] && [ -s "$base/lib/libTVAppleRuntime.a" ] || return 1
  cmp -s "$OUT/lib/libTVAppleRuntime.a" "$base/lib/libTVAppleRuntime.a" || return 1
  [ -s "$base/include/jni.h" ] && [ -s "$base/include/jni_md.h" ] && [ -d "$base/Resources/lib/conf/security" ] && [ -d "$base/Resources/lib/lib/security" ] || return 1
  [ -x "$work/openjdk-mobile/build/macosx-host/images/jdk/bin/jlink" ] && [ -x "$work/openjdk-mobile/build/macosx-host/images/jdk/bin/jimage" ] && [ -x "$work/openjdk-mobile/build/macosx-host/images/jdk/bin/jmod" ] || return 1
  [ -s "$work/openjdk-mobile/build/$CONF/spec.gmk" ] && [ -s "$work/native-$TARGET/apple-bindings.jar" ] || return 1
  local boot="$work/boot-jdk/jdk-26.0.2.1+1/Contents/Home"
  [ -s "$boot/conf/security/java.security" ] && [ -d "$boot/conf/security/policy" ] && [ -s "$boot/lib/security/cacerts" ] && [ -s "$boot/lib/tzdb.dat" ] || return 1
  [ -s "$work/openjdk-mobile/build/$CONF/jdk/modules/java.base/java/lang/Object.class" ] || return 1
  local module
  for module in java.base java.management java.logging java.naming java.security.sasl java.xml jdk.zipfs jdk.httpserver jdk.unsupported jdk.charsets; do
    [ -s "$work/openjdk-mobile/build/$CONF/jdk/modules/$module/module-info.class" ] || return 1
  done
}
export CCTV_JAR_REUSE_NATIVE=0
if native_cache_ready; then
  export CCTV_JAR_REUSE_NATIVE=1
  echo "Reusing verified $PLATFORM native engine; rebuilding resources only"
elif [ -d "$SOURCE/build/apple-runtime" ] && [ ! -d "$SOURCE/build/apple-runtime/openjdk-mobile/.git" ]; then
  # A partial relink kit is not a complete source checkout for a cold rebuild.
  rm -rf "$SOURCE/build/apple-runtime"
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
if [ "$TARGET" = ios ]; then
  python3 "$ROOT/Scripts/check_jar_compatibility.py" --source "$SOURCE" \
    --baseline-host "$SOURCE/build/AppleRuntime/$PLATFORM/Resources/JavaHost" \
    --candidate-host "$OUT/Resources/JavaHost" --java-home "$JAVA_HOME" \
    --output "$OUT/compatibility"
fi
printf '%s\n' "$STAMP" > "$OUT/complete"
echo "Prepared JAR runtime: $OUT"
