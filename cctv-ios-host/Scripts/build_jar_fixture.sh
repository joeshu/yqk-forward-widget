#!/bin/bash
# Rebuild the controlled DEX-only fixture from its corresponding Java source.
set -euo pipefail
cd "$(dirname "$0")/.."
HOST="${1:?Pass a JavaHost folder containing host.jar and lib/*.jar}"
JDK="${JAVA_HOME:?Set JAVA_HOME to a JDK (17 or newer)}"
WORK="${TMPDIR:-/tmp}/cctv-jar-fixture"
mkdir -p "$WORK/classes" "$WORK/dex"
R8="$WORK/r8-8.3.37.jar"
if [ ! -f "$R8" ]; then curl -fL --retry 2 https://storage.googleapis.com/r8-releases/raw/8.3.37/r8.jar -o "$R8"; fi
echo "900dfbc649519969fc5a4c7520d6b7355338e565fa1249874e0190b8d61b1199  $R8" | shasum -a 256 -c -
"$JDK/bin/javac" --release 8 -encoding UTF-8 -cp "$HOST/host.jar:$HOST/lib/*" -d "$WORK/classes" Tests/JARFixture/CCTVFixture.java
LIBS=()
for file in "$HOST"/lib/*.jar; do LIBS+=(--classpath "$file"); done
"$JDK/bin/java" -cp "$R8" com.android.tools.r8.D8 --release --min-api 21 --lib "$JDK" --classpath "$HOST/host.jar" "${LIBS[@]}" --output "$WORK/dex" "$WORK/classes/com/github/catvod/spider/CCTVFixture.class"
python3 - "$WORK/dex/classes.dex" <<'PY'
from pathlib import Path
from zipfile import ZipFile,ZipInfo,ZIP_DEFLATED
from io import BytesIO
import base64,sys
out=BytesIO()
with ZipFile(out,'w',ZIP_DEFLATED) as jar:
 info=ZipInfo('classes.dex',(2026,1,1,0,0,0));info.compress_type=ZIP_DEFLATED
 jar.writestr(info,Path(sys.argv[1]).read_bytes())
Path('Tests/JARFixture/fixture.jar.b64').write_bytes(base64.encodebytes(out.getvalue()))
PY
