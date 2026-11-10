#!/bin/bash
# Apple SDK static analysis; reports diagnostics, never claims runtime or binary-SDK coverage.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-native-audit}"
mkdir -p "$OUT"
rm -f "$OUT/compile-failures.txt" "$OUT"/*.plist "$OUT"/*.skipped
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
PYTHON_INCLUDE=/tmp/pyroot/Python.xcframework/ios-arm64/include/python3.13
analyze_source() {
  local source="$1" name
  name="$(basename "$source" .m)"
  if [[ "$name" = PyHost ]] && [ ! -d "$PYTHON_INCLUDE" ]; then
    echo 'Python SDK unavailable: analysis deferred to full build' > "$OUT/$name.skipped"
    return
  fi
  local extra=(-DCCTV_JAR_ENABLED=1)
  [ ! -d "$PYTHON_INCLUDE" ] || extra+=(-I "$PYTHON_INCLUDE" -F build/CCTVHost.app/Frameworks)
  echo "Analyzing $source"
  xcrun --sdk iphoneos clang --analyze -fobjc-arc -arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 \
    -I Sources -I Sources/Include -F Frameworks "${extra[@]}" \
    -Xanalyzer -analyzer-output=plist "$source" -o "$OUT/$name.plist" > "$OUT/$name.log" 2>&1 || echo "$source" >> "$OUT/compile-failures.txt"
}
export -f analyze_source
export SDK OUT PYTHON_INCLUDE
SOURCES=(Sources/*.m)
if [ "${CCTV_AUDIT_ONLY:-}" = PyHost ]; then SOURCES=(Sources/PyHost.m); fi
# Two independent compiler processes keep memory bounded on Apple silicon runners.
printf '%s\0' "${SOURCES[@]}" | xargs -0 -n 1 -P 2 bash -c 'analyze_source "$1"' _
python3 - "$OUT" <<'PY'
from pathlib import Path
import json,plistlib,sys
root=Path(sys.argv[1]);files=[]
for path in sorted(root.glob('*.plist')):
 data=plistlib.loads(path.read_bytes());diagnostics=[]
 for item in data.get('diagnostics',[]):
  loc=item.get('location',{});sources=data.get('files',[]);index=loc.get('file',0)
  diagnostics.append({'description':item.get('description'),'category':item.get('category'),'checker':item.get('check_name'),'file':sources[index] if index<len(sources) else path.stem,'line':loc.get('line')})
 files.append({'source':path.stem+'.m','diagnostics':diagnostics})
failures=(root/'compile-failures.txt').read_text().splitlines() if (root/'compile-failures.txt').exists() else []
report={'analyzed':len(files),'skipped':[p.name for p in root.glob('*.skipped')],'diagnostics':sum(len(f['diagnostics']) for f in files),'compile_failures':failures,'files':files}
(root/'summary.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k!='files'},indent=2))
for file in files:
 for item in file['diagnostics']:print(json.dumps(item,ensure_ascii=False))
for source in failures:
 log=root/(Path(source).stem+'.log')
 for line in log.read_text(errors='replace').splitlines():
  if 'error:' in line:print(line)
if failures:raise SystemExit(1)
PY
