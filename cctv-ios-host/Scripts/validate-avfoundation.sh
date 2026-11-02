#!/bin/bash
# Run real macOS AVFoundation against the same MP4 bytes on disk and over HTTP.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $0 INPUT_DIRECTORY [OUTPUT_DIRECTORY] [--allow-failures]" >&2
  exit 2
fi
INPUT_DIRECTORY=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$1")
OUTPUT_DIRECTORY=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "${2:-validation-results}")
mkdir -p "$OUTPUT_DIRECTORY"
xcrun --sdk macosx clang -O2 -fobjc-arc -Wall -Wextra -Wno-deprecated-declarations \
  Scripts/validate-avfoundation.m -framework Foundation -framework AVFoundation \
  -framework CoreMedia -framework CoreGraphics -framework ImageIO \
  -o "$OUTPUT_DIRECTORY/validate-avfoundation"
PORT_FILE="$OUTPUT_DIRECTORY/server-port.txt"
rm -f "$PORT_FILE" "$OUTPUT_DIRECTORY/http-requests.jsonl"
python3 -u Scripts/media-validation-server.py --directory "$INPUT_DIRECTORY" \
  --port-file "$PORT_FILE" --request-log "$OUTPUT_DIRECTORY/http-requests.jsonl" \
  > "$OUTPUT_DIRECTORY/http-server.log" 2>&1 &
SERVER_PID=$!
cleanup() { kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; }
trap cleanup EXIT
for attempt in $(seq 1 300); do
  if [ -s "$PORT_FILE" ]; then break; fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then cat "$OUTPUT_DIRECTORY/http-server.log"; exit 1; fi
  sleep 0.1
done
if [ ! -s "$PORT_FILE" ]; then cat "$OUTPUT_DIRECTORY/http-server.log"; exit 1; fi
PORT=$(cat "$PORT_FILE")
set +e
if [ "$#" -eq 3 ]; then
  "$OUTPUT_DIRECTORY/validate-avfoundation" "$INPUT_DIRECTORY" "$OUTPUT_DIRECTORY" \
    "http://127.0.0.1:$PORT/" "$3" 2>&1 | tee "$OUTPUT_DIRECTORY/avfoundation.log"
  VALIDATION_STATUS=${PIPESTATUS[0]}
else
  "$OUTPUT_DIRECTORY/validate-avfoundation" "$INPUT_DIRECTORY" "$OUTPUT_DIRECTORY" \
    "http://127.0.0.1:$PORT/" 2>&1 | tee "$OUTPUT_DIRECTORY/avfoundation.log"
  VALIDATION_STATUS=${PIPESTATUS[0]}
fi
set -e
cleanup
trap - EXIT
python3 - "$OUTPUT_DIRECTORY" <<'PY'
import collections
import json
import pathlib
import sys

output = pathlib.Path(sys.argv[1])
requests = [json.loads(line) for line in (output / 'http-requests.jsonl').read_text().splitlines() if line]
counts = collections.Counter(str(item['status']) for item in requests)
results_file = output / 'results.json'
samples = json.loads(results_file.read_text()).get('samples', []) if results_file.exists() else []
required = {sample['file'] for sample in samples if not sample.get('expected_invalid')}
partial_paths = {item['path'] for item in requests if item['status'] == 206 and item.get('range')}
missing = sorted(required - partial_paths)
summary = {
    'request_count': len(requests),
    'range_request_count': sum(bool(item.get('range')) for item in requests),
    'partial_response_count': counts['206'],
    'status_counts': dict(counts),
    'required_sample_count': len(required),
    'required_samples_with_partial_responses': len(required & partial_paths),
    'required_samples_missing_partial_responses': missing,
    'passed': bool(required) and not missing,
}
(output / 'http-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary, indent=2))
if not summary['passed']:
    raise SystemExit(1)
PY
exit "$VALIDATION_STATUS"
