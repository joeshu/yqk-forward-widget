#!/bin/sh
# 去掉残留签名并做一次 ad-hoc 签名，便于本地快速验证 dylib 依赖（正式安装请用 Xcode/开发者证书）
set -e
APP="${1:?usage: resign-check.sh /path/to/CCTVHost.app}"
for f in "$APP"/Frameworks/*.framework; do
  codesign --remove-signature "$f/$(basename "$f" .framework)" 2>/dev/null || true
done
codesign --remove-signature "$APP/CCTVHost" 2>/dev/null || true
for f in "$APP"/Frameworks/*.framework; do
  codesign -f -s - "$f/$(basename "$f" .framework)"
done
codesign -f -s - "$APP"
codesign -dv --verbose=2 "$APP" 2>&1 | head -5
