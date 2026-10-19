#!/usr/bin/env python3
"""下载咪咕 M3U 列表，修正频道属性，并保存为 UTF-8 .m3u8 文件。"""

import argparse
import os
from pathlib import Path
import re
import sys
import tempfile
from urllib.request import Request, urlopen


DEFAULT_SOURCE = "http://www.52top.com.cn:678/downloads/migu.txt"
MAX_BYTES = 8 * 1024 * 1024
# 保留频道显示名称，仅修正与原列表所附 XMLTV 节目单对应的 ID。
EPG_ID_ALIASES = {"上视新闻综合": "上海新闻综合"}


def normalize(raw):
    lines = raw.decode("utf-8-sig").splitlines()
    if not lines or not (
        lines[0] == "#EXTM3U" or lines[0].startswith("#EXTM3U ")
    ):
        raise ValueError("来源不是有效的扩展 M3U 列表，已保留原输出文件")

    result = [lines[0]]
    pending = False
    count = 0
    for line in lines[1:]:
        if not line.strip():
            continue
        if line.startswith("#EXTINF:"):
            if pending or "," not in line:
                raise ValueError("频道信息缺少播放地址或格式不完整")
            # 只修改元数据属性，完整保留播放地址及其鉴权参数。
            for suffix in ("id", "name"):
                if not re.search(r'(?<!\S)tvg-' + suffix + r'\s*=', line):
                    line = re.sub(
                        r'(?<!\S)svg-' + suffix + r'(?=\s*=)',
                        "tvg-" + suffix,
                        line,
                    )
            line = re.sub(
                r'(?<!\S)tvg-id="([^"]*)"',
                lambda match: 'tvg-id="'
                + EPG_ID_ALIASES.get(match[1], match[1])
                + '"',
                line,
            )
            pending = True
        elif not line.startswith("#"):
            if not pending or not line.startswith(("http://", "https://")):
                raise ValueError("播放地址格式异常，已保留原输出文件")
            count += 1
            pending = False
        result.append(line)
    if pending or not count:
        raise ValueError("列表为空或缺少最后一个频道的播放地址")
    return ("\n".join(result) + "\n").encode("utf-8"), count


def atomic_write(output, data):
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=output.parent, delete=False) as handle:
            temporary = Path(handle.name)
            handle.write(data)
        os.replace(temporary, output)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", default=DEFAULT_SOURCE, help="远程列表 URL")
    parser.add_argument("--input", type=Path, help="改为读取本地文件")
    parser.add_argument("--output", type=Path, default=Path("migu.m3u8"))
    args = parser.parse_args()
    try:
        if args.input:
            with args.input.open("rb") as handle:
                raw = handle.read(MAX_BYTES + 1)
        else:
            request = Request(args.source, headers={"User-Agent": "MiguPlaylistUpdater/1.0"})
            with urlopen(request, timeout=30) as response:
                raw = response.read(MAX_BYTES + 1)
        if len(raw) > MAX_BYTES:
            raise ValueError("来源超过 8 MiB，已保留原输出文件")
        data, count = normalize(raw)
        atomic_write(args.output, data)
    except (OSError, ValueError) as error:
        print(f"更新失败：{error}", file=sys.stderr)
        return 1
    print(f"已保存 {count} 个频道到 {args.output}")
    print("仅更新列表；不刷新或延长上游鉴权，也不验证全部频道播放。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
