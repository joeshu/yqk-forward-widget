#!/usr/bin/env python3
"""Sample actual HLS media manifests; never download media segments or keys."""
from concurrent.futures import ThreadPoolExecutor
import argparse
from pathlib import Path
import re
import sys
import threading
import time
from urllib.parse import urljoin, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import update_migu as m


def hls_references(raw, base):
    try:
        text = raw.decode("utf-8-sig").replace("\r\n", "\n")
    except UnicodeError:
        raise m.UpdateError("HLS_NOT_UTF8") from None
    if not m.clean_text(text.replace("\n", "")):
        raise m.UpdateError("HLS_CONTROL_CHARACTER")
    lines = [line.strip() for line in text.split("\n") if line.strip()]
    if not lines or lines[0] != "#EXTM3U" or any(len(line) > m.MAX_LINE for line in lines):
        raise m.UpdateError("HLS_HEADER_INVALID")
    master = any(line.startswith("#EXT-X-STREAM-INF:") for line in lines)
    media = any(line.startswith("#EXTINF:") for line in lines)
    if master and media:
        raise m.UpdateError("HLS_MIXED_PLAYLIST")
    references = []
    if master:
        for index, line in enumerate(lines):
            if line.startswith("#EXT-X-STREAM-INF:"):
                if index + 1 >= len(lines) or lines[index + 1].startswith("#"):
                    raise m.UpdateError("HLS_VARIANT_MISSING")
                references.append(urljoin(base, lines[index + 1]))
    elif media:
        if not any(re.fullmatch(r"#EXT-X-TARGETDURATION:[1-9]\d*", line) for line in lines):
            raise m.UpdateError("HLS_TARGET_DURATION_MISSING")
        pending = False
        for line in lines:
            if line.startswith("#EXTINF:"):
                if pending:
                    raise m.UpdateError("HLS_SEGMENT_MISSING")
                try:
                    duration = float(line[len("#EXTINF:"):].split(",", 1)[0])
                except ValueError:
                    raise m.UpdateError("HLS_DURATION_INVALID") from None
                if not 0 < duration < float("inf"):
                    raise m.UpdateError("HLS_DURATION_INVALID")
                pending = True
            elif not line.startswith("#"):
                if not pending:
                    raise m.UpdateError("HLS_SEGMENT_WITHOUT_DURATION")
                references.append(urljoin(base, line))
                pending = False
        if pending:
            raise m.UpdateError("HLS_SEGMENT_MISSING")
    if not references:
        raise m.UpdateError("HLS_EMPTY_PLAYLIST")
    for reference in references:
        m.validate_url(reference, "media")
    return "master" if master else "media", references


def sample_channels(channels, count):
    selected, groups = [], set()
    for index, channel in enumerate(channels):
        if channel.group not in groups:
            selected.append(index)
            groups.add(channel.group)
            if len(selected) == count:
                break
    for index in range(len(channels)):
        if len(selected) >= count:
            break
        if index not in selected:
            selected.append(index)
    return [channels[index] for index in selected]


def probe_channel(channel, stop):
    started = time.monotonic()
    result = {"channel": channel.display, "group": channel.group, "entry_manifest_accessible": False, "media_manifest_accessible": False, "video_decoded": False, "requests": 0}
    if stop.is_set():
        return {**result, "error": "SKIPPED_AFTER_RATE_LIMIT"}
    client = m.HttpClient("media", attempts=1, timeout=8, budget=18)
    url, visited, all_https = channel.url, set(), True
    try:
        for depth in range(3):
            if stop.is_set():
                raise m.UpdateError("SKIPPED_AFTER_RATE_LIMIT")
            if url in visited:
                raise m.UpdateError("HLS_CYCLE")
            visited.add(url)
            result["stage"] = "entry_manifest" if depth == 0 else "child_manifest"
            result["requests"] += 1
            raw, _ = client.get(url, limit=512 * 1024)
            if raw is None:
                raise m.UpdateError("HLS_UNEXPECTED_304")
            all_https = all_https and urlsplit(url).scheme == "https" and urlsplit(client.last_url).scheme == "https"
            kind, references = hls_references(raw, client.last_url)
            if depth == 0:
                result["entry_manifest_accessible"] = True
            if kind == "media":
                result.update(media_manifest_accessible=True, stage="media_manifest", segment_count=len(references), manifests_and_segment_urls_https=all_https and all(urlsplit(ref).scheme == "https" for ref in references))
                break
            url = references[0]
        else:
            raise m.UpdateError("HLS_DEPTH_LIMIT")
    except m.UpdateError as error:
        result["error"] = str(error)
        if str(error) == "HTTP_429":
            stop.set()
    except (OSError, ValueError):
        result["error"] = "PROBE_NETWORK_OR_FORMAT_ERROR"
    result["seconds"] = round(time.monotonic() - started, 3)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=Path("migu.m3u8"))
    parser.add_argument("--sample", type=int, default=5)
    parser.add_argument("--report", type=Path, default=Path("migu-check.json"))
    args = parser.parse_args(argv)
    if not 1 <= args.sample <= 12:
        parser.error("sample must be in [1, 12]")
    if args.input.resolve() == args.report.resolve():
        parser.error("input and report must differ")
    try:
        with args.input.open("rb") as handle:
            raw = handle.read(m.MAX_BYTES + 1)
        playlist = m.parse_playlist(raw)
        selected = sample_channels(playlist.channels, args.sample)
        stop = threading.Event()
        with ThreadPoolExecutor(max_workers=2) as executor:
            results = list(executor.map(lambda channel: probe_channel(channel, stop), selected))
        report = {"checked_at_utc": m.iso(m.utcnow()), "catalogue_sha256": m.digest(raw), "updater_sha256": m.digest(Path(m.__file__).read_bytes()), "probe_sha256": m.digest(Path(__file__).read_bytes()), "sample_size": len(results), "media_manifests_accessible": sum(row["media_manifest_accessible"] for row in results), "video_segments_downloaded": False, "video_decoded": False, "scope": "Current execution network only; failures do not determine playback in another region/device.", "results": results}
        m.atomic_write(args.report, m.json_bytes(report))
        print(f"媒体清单可访问：{report['media_manifests_accessible']}/{len(results)}；未下载分片、未验证视频解码。")
        return 0 if all(row["media_manifest_accessible"] for row in results) else 1
    except (OSError, ValueError):
        print("检查失败：输入、网络策略或输出文件异常。", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
