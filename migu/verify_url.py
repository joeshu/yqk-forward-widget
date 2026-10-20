#!/usr/bin/env python3
"""Offline structure check for one issued Migu playback URL.

Never prints the full URL, session fields or signature values.  It answers one
question: which client rule produced this URL's ddCalcu, and does it verify?

Usage:
    python3 -m migu.verify_url '<url>'
    python3 -m migu.verify_url --file list.txt
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from migu import android as a
from migu import core as m
from migu.native import NativeAuth, NATIVE_SETTINGS, native_proof

SENSITIVE = {"msisdn", "SecurityKey", "puData", "ddCalcu", "sid", "assertID", "mvid",
             "client_ip", "userid", "jmhm", "pid", "spid", "mcid"}


def analyse(url):
    parts = urlsplit(url.strip())
    query = parse_qs(parts.query, keep_blank_values=True)
    one = lambda key: (query.get(key) or [""])[0]
    pu_data, given = one("puData"), one("ddCalcu")
    pid, timestamp = one("ProgramID"), one("timestamp")
    result = {
        "host": parts.hostname or "",
        "path_depth": len([part for part in parts.path.split("/") if part]),
        "query_fields": len(query),
        "pu_data_len": len(pu_data),
        "dd_calcu_len": len(given),
        "timestamp_present": bool(timestamp),
        "client_id_family": one("Channel_ID").split("-")[0],
        "app_code": one("appCode"),
        "terminal": one("tid") or one("bean"),
        "session_fields": sorted(name for name in SENSITIVE if name in query),
        "legacy_match": None,
        "modern_match": None,
    }
    if pu_data and pid and timestamp:
        auth = NativeAuth.load({**NATIVE_SETTINGS}, environ={})
        try:
            legacy = native_proof(pu_data, pid, timestamp, auth, 3)
            result["legacy_match"] = bool(given) and legacy == given
        except (ValueError, IndexError, m.UpdateError):
            result["legacy_match"] = False
        modern = a.dd_calcu(pu_data, pid, 3, timestamp=timestamp)
        result["modern_match"] = bool(given) and modern == given
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url", nargs="?")
    parser.add_argument("--file", type=Path)
    args = parser.parse_args(argv)
    urls = []
    if args.file:
        urls = [line.strip() for line in args.file.read_text("utf-8").splitlines() if line.startswith("http")]
    elif args.url:
        urls = [args.url]
    else:
        parser.error("provide a URL or --file")
    rows = [analyse(url) for url in urls]
    if len(rows) == 1:
        for key, value in rows[0].items():
            print(f"{key}: {value}")
    else:
        legacy = sum(1 for row in rows if row["legacy_match"])
        modern = sum(1 for row in rows if row["modern_match"])
        print(f"urls: {len(rows)}")
        print(f"legacy_rule_matches: {legacy}")
        print(f"modern_rule_matches: {modern}")
        families = sorted({row["client_id_family"] for row in rows})
        print(f"client_id_families: {families}")
        print(f"app_codes: {sorted({row['app_code'] for row in rows})}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
