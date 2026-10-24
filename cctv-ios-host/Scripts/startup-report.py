#!/usr/bin/env python3
"""Summarize measured first video frames; never counts item-ready as a frame."""
import argparse
import json
import math
import re
import statistics
from pathlib import Path


def summarize(text):
    session = "unknown"
    mode = "unknown"
    groups = {}
    for line in text.splitlines():
        if "CCTVHost " in line and "SDK" in line:
            match = re.search(r"CCTVHost\s+(\S+)", line)
            if match:
                session = match[1]
        if "variant " in line:
            session_variant = line.split("variant ")[-1].strip()
        else:
            session_variant = None
        if session_variant:
            session = session.split("/")[0] + "/" + session_variant
        if "原生起播 " in line:
            mode = "reuse" if "复用" in line else "fresh"
        match = re.search(r"(订阅视频首帧|首帧渲染)\s+([0-9.]+)s", line)
        if match:
            engine = "AVPlayer" if match[1] == "订阅视频首帧" else "CNPlayerSDK/" + mode
            groups.setdefault(session + "/" + engine, []).append(float(match[2]))
    result = {}
    for key, samples in groups.items():
        ordered = sorted(samples)
        result[key] = {"samples": len(samples), "median_seconds": statistics.median(samples),
                       "p95_seconds": ordered[math.ceil(.95 * len(ordered)) - 1],
                       "min_seconds": ordered[0], "max_seconds": ordered[-1]}
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", nargs="+", type=Path)
    args = parser.parse_args()
    print(json.dumps({str(p): summarize(p.read_text(errors="replace")) for p in args.logs}, ensure_ascii=False, indent=2))
