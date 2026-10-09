"""Development-only transport: real HTTPS through Python's standard proxy support.
Not part of the JS Widget runtime. Receives one request on stdin; never logs bodies.
"""
import gzip
import base64
import json
import sys
import urllib.error
import urllib.request

request = json.load(sys.stdin)
if not request["url"].startswith("https://"):
    raise ValueError("HTTPS required")
headers = request.get("headers", {})
body = request.get("body")
req = urllib.request.Request(
    request["url"],
    data=body.encode() if body is not None else None,
    headers=headers,
    method=request.get("method", "GET"),
)
try:
    response = urllib.request.urlopen(req, timeout=25)
except urllib.error.HTTPError as exc:
    response = exc
with response:
    content = response.read(16 * 1024 * 1024 + 1)
    if len(content) > 16 * 1024 * 1024:
        raise ValueError("Development response exceeds 16 MiB")
    if content.startswith(b"\x1f\x8b"):
        content = gzip.decompress(content)
    result_headers = dict(response.headers)
    for key in list(result_headers):
        if key.lower() in ("content-encoding", "content-length"):
            del result_headers[key]
    print(json.dumps({"status": response.status, "headers": result_headers,
                      "text": content.decode("utf-8", errors="replace"),
                      "bodyBase64": base64.b64encode(content).decode("ascii")}))
