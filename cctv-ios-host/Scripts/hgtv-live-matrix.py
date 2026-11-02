#!/usr/bin/env python3
"""Acquire real HGTV fixtures for the macOS AVFoundation compatibility job.

This is an opt-in online check, not a unit test. It downloads only the selected
episodes, never the complete series. Python adapters run with ffmpeg disabled.
The Node adapter decrypts the same encrypted CDN bytes as Python 1.0.5, avoiding
another download while exercising its own MP4 parser and AES-CTR implementation.
Signed URLs, model payloads, and decryption keys are never written to the report.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[1]
QUALITIES = ("360p", "480p", "540p", "720p", "1080p")
SERIES = {
    "7701564849850960921": {"expected_count": 215},
    "7701226234214108185": {"expected_count": 300},
}
EPISODES = {
    "7701565033376910360": "7701564849850960921",
    "7701820244146261016": "7701226234214108185",
    "7701832903004556312": "7701226234214108185",
}
DEFAULT_EPISODES = tuple(EPISODES)[:2]
SOURCES = {
    "py105": ROOT / "Examples/hgtv-python/hgtv_public_1_0_5.py",
    "py104": ROOT / "Examples/hgtv-python-1.0.4/hgtv_public_1_0_4.py",
}


def safe_error(error):
    """Keep useful exception classes without leaking signed request data."""
    message = re.sub(r"https?://[^\s]+", "[redacted URL]", str(error))
    message = re.sub(r"(?i)(?:authorization|cookie|token|signature|spade|key)\s*[:=].*",
                     "[redacted credentials]", message)
    return {"type": type(error).__name__, "message": message[:240]}


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as media:
        for chunk in iter(lambda: media.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def output_bytes(output):
    return sum(path.stat().st_size for path in output.rglob("*.mp4") if path.is_file())


class ByteBudget:
    def __init__(self, output, limit):
        self.output, self.limit = output, limit
        self.downloaded = 0

    def ensure(self, additional):
        if output_bytes(self.output) + additional > self.limit:
            raise RuntimeError("media output exceeds --max-total-mb budget")

    def urlopen(self, original, request, **kwargs):
        response = original(request, **kwargs)
        # Only this alias's GET calls download the source MP4. Catalogue reads
        # use PublicHTTP's own opener; signed model calls use POST.
        if request.get_method() != "GET":
            return response
        length = response.headers.get("Content-Length")
        try:
            self.ensure(int(length)) if length and length.isdigit() else None
        except Exception:
            response.close()
            raise
        budget = self

        class BoundedResponse:
            def __enter__(self):
                response.__enter__()
                return self

            def __exit__(self, *args):
                return response.__exit__(*args)

            def read(self, size=-1):
                data = response.read(size)
                budget.ensure(len(data))
                budget.downloaded += len(data)
                return data

        return BoundedResponse()


class NodeAdapter:
    def __init__(self, temp, output, budget):
        self.output, self.budget = output, budget
        self.results = {}
        self.node = shutil.which("node")
        if not self.node:
            raise RuntimeError("Node.js is required; use --runtimes py105,py104 to omit Node")
        source = (ROOT / "Examples/hgtv-node/hgtv.js").read_text()
        marker = "module.exports = site;"
        if source.count(marker) != 1:
            raise RuntimeError("cannot locate HGTV Node adapter export")
        self.module = Path(temp) / "hgtv-live.cjs"
        self.module.write_text(source.replace(marker,
            "module.exports = {decryptCenc, verifyMp4, qualityCandidates, pickBest, deriveContentKey};"))
        self.runner = Path(temp) / "runner.cjs"
        self.runner.write_text("""const fs = require('node:fs');
const api = require(process.argv[2]);
const p = JSON.parse(fs.readFileSync(0, 'utf8'));
let result;
if (p.action === 'catalog') {
  result = Object.entries(p.models).map(([id, model]) => {
    const candidates = api.qualityCandidates(model);
    const decryptable = candidates.some(c => {
      const info = c.it.encrypt_info || {};
      const encrypted = !!info.encrypt || /1:encrypt/.test(String(c.it.gear_des_key || ''));
      try {
        const key = api.deriveContentKey(c.it.spade_a || info.spade_a || '');
        return !encrypted || !!(key && key.length === 16);
      }
      catch (_) { return false; }
    });
    return {episode_id: id, compatible_qualities: [...new Set(candidates.map(c => c.q))],
      has_decryptable_quality: decryptable, status: candidates.length && decryptable ? 'passed' : 'failed'};
  });
} else if (p.action === 'model') {
  result = {offered: [...new Set(api.qualityCandidates(p.model).map(c => c.q))],
    selected: Object.fromEntries(p.qualities.map(q => [q, (api.pickBest(p.model, q) || {}).q || null]))};
} else {
  if (p.action === 'decrypt') api.decryptCenc(p.src, p.dst, Buffer.from(p.key, 'hex'));
  result = {verified: api.verifyMp4(p.dst)};
}
process.stdout.write(JSON.stringify(result));
""")

    def run(self, payload):
        result = subprocess.run([self.node, str(self.runner), str(self.module)],
                                input=json.dumps(payload), capture_output=True,
                                text=True, timeout=180)
        if result.returncode:
            # Do not include arbitrary subprocess stderr (or the input model).
            raise RuntimeError("HGTV Node runner exited %d" % result.returncode)
        return json.loads(result.stdout)

    def model(self, model, qualities):
        return self.run({"action": "model", "model": model, "qualities": qualities})

    def decrypt(self, encrypted, key, episode_id, quality):
        target = self.output / "node/media" / (episode_id + "_" + quality + ".mp4")
        target.parent.mkdir(parents=True, exist_ok=True)
        self.budget.ensure(Path(encrypted).stat().st_size)
        started = time.monotonic()
        result = self.run({"action": "decrypt", "src": str(encrypted),
                           "dst": str(target), "key": key.hex()})
        if not result.get("verified"):
            raise RuntimeError("HGTV Node clear-MP4 structural verification failed")
        self.results[(episode_id, quality)] = {
            "status": "passed", "file": str(target.relative_to(self.output)),
            "bytes": target.stat().st_size, "sha256": sha256(target),
            "elapsed_seconds": round(time.monotonic() - started, 3),
            "decryption_path": "node-decryptCenc",
        }


def load_adapter(runtime, output, budget):
    sys.path.insert(0, str(ROOT / "Plugins/crypto_compat"))
    sys.path.insert(0, str(ROOT / "Plugins"))
    spec = importlib.util.spec_from_file_location("hgtv_live_" + runtime, SOURCES[runtime])
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module._DEC_DIR = str(output / runtime / "media")
    module._ffmpeg_path = lambda: ""
    # Give the module an alias facade instead of mutating urllib.request itself.
    original = module._ureq
    module._ureq = SimpleNamespace(Request=original.Request,
        urlopen=lambda request, **kwargs: budget.urlopen(original.urlopen, request, **kwargs))
    return module


def model_summary(module, model):
    offered = set()
    for key, item in (model.get("video_list") or {}).items():
        if isinstance(item, dict):
            offered.add(module._video_quality(item, key))
    compatible = [quality for quality in QUALITIES if module._pick_best(model, quality)]
    return {"offered_qualities": sorted(offered), "compatible_qualities": compatible}


def batch_models(module, episode_ids):
    payload = json.dumps({"biz_param": {
        "detail_page_version": 0, "device_level": 3, "disable_digg_stat": False,
        "need_all_video_definition": True, "need_mp4_align": False,
        "use_os_player": False, "use_server_dns": False, "video_platform": 1024},
        "mixed_video_id_map": {"1004": episode_ids}}, separators=(",", ":"))
    last_error = None
    for attempt in range(3):
        try:
            url, headers, body = module._signed_request(payload)
            request = module._ureq.Request(url, data=body, headers=headers, method="POST")
            with module._ureq.urlopen(request, timeout=30) as response:
                data = response.read(16 * 1024 * 1024 + 1)
            if len(data) > 16 * 1024 * 1024:
                raise RuntimeError("batch model response exceeds 16 MiB")
            result = json.loads(data)
            if result.get("code") not in (0, None) or not isinstance(result.get("data"), dict):
                raise RuntimeError("signed batch API rejected catalogue model request")
            return result["data"]
        except Exception as error:
            last_error = error
            if attempt < 2:
                time.sleep(0.6)
    raise last_error


def verify_all_models(module, episodes, models):
    checks = []
    # The live provider accepts ten IDs; twenty returns code 100001 参数错误.
    for offset in range(0, len(episodes), 10):
        batch = episodes[offset:offset + 10]
        result = batch_models(module, [episode["id"] for episode in batch])
        for episode in batch:
            check = {"episode_id": episode["id"], "episode_number": episode["number"], "status": "failed"}
            checks.append(check)
            try:
                model = (result.get(episode["id"]) or {}).get("video_model")
                if isinstance(model, str):
                    model = json.loads(model)
                if not isinstance(model, dict):
                    raise RuntimeError("batch response has no episode model")
                if isinstance(model.get("video_list"), list):
                    model["video_list"] = {str(index): item for index, item in enumerate(model["video_list"])}
                check.update(model_summary(module, model))
                decryptable = False
                for quality in check["compatible_qualities"]:
                    item, _quality = module._pick_best(model, quality)
                    info = item.get("encrypt_info") or {}
                    spade = item.get("spade_a") or info.get("spade_a")
                    key = module._content_key(spade) if spade else None
                    if not module._is_encrypted(item) or (key and re.fullmatch(r"[0-9a-fA-F]{32}", key)):
                        decryptable = True
                        break
                check["has_decryptable_quality"] = decryptable
                if not decryptable:
                    raise RuntimeError("episode has no compatible quality with a derivable content key")
                models[episode["id"]] = model
                module._SIGN_CACHE[episode["id"]] = (time.time(), model)
                check["status"] = "passed"
            except Exception as error:
                check["error"] = safe_error(error)
    return checks


def verify_catalog(module, runtime, report, models, all_models=False, node=None):
    catalog = module.Catalog(module.PublicHTTP())
    for series_id, expected in SERIES.items():
        row = {"runtime": runtime, "series_id": series_id, **expected,
               "status": "failed", "model_probes": []}
        report["catalogs"].append(row)
        try:
            for attempt in range(3):
                try:
                    detail = catalog.detail(series_id)
                    break
                except Exception:
                    if attempt == 2:
                        raise
                    time.sleep(0.6)
            row.update(title=detail["title"], episode_count=detail["episode_count"],
                       declared_count=detail["count"], catalog_complete=detail["catalog_complete"],
                       invalid_episode_entries=detail["invalid_episode_entries"],
                       duplicate_episode_entries=detail["duplicate_episode_entries"])
            if detail["episode_count"] != expected["expected_count"] or not detail["catalog_complete"]:
                raise RuntimeError("live series catalogue count or completeness differs from expectation")
            episodes = detail["episodes"]
            if all_models:
                row["all_model_checks"] = verify_all_models(module, episodes, models)
                row["all_model_count"] = len(row["all_model_checks"])
                row["all_model_batch_size"] = 10
                row["all_model_passed_count"] = sum(check["status"] == "passed" for check in row["all_model_checks"])
                if node:
                    node_row = {"runtime": "node", "series_id": series_id, **expected,
                                "status": "failed", "episode_count": len(episodes),
                                "catalog_complete": True, "acquisition_runtime": runtime,
                                "provenance": "live Python-acquired catalogue/model bytes; independent Node quality/key parsing"}
                    report["catalogs"].append(node_row)
                    node_row["all_model_checks"] = node.run({"action": "catalog", "models": {
                        episode["id"]: models[episode["id"]] for episode in episodes if episode["id"] in models}})
                    node_row["all_model_count"] = len(node_row["all_model_checks"])
                    node_row["all_model_passed_count"] = sum(check["status"] == "passed" for check in node_row["all_model_checks"])
                    if node_row["all_model_passed_count"] == len(episodes):
                        node_row["status"] = "passed"
            for label, episode in (("first", episodes[0]),
                                   ("middle", episodes[len(episodes) // 2]),
                                   ("last", episodes[-1])):
                probe = {"position": label, "episode_id": episode["id"],
                         "episode_number": episode["number"], "status": "failed"}
                row["model_probes"].append(probe)
                try:
                    model = module._signed_model(episode["id"])
                    if not model:
                        raise RuntimeError("signed API returned no model")
                    models[episode["id"]] = model
                    probe.update(model_summary(module, model))
                    if not probe["compatible_qualities"]:
                        raise RuntimeError("signed model has no compatible advertised qualities")
                    probe["status"] = "passed"
                except Exception as error:
                    probe["error"] = safe_error(error)
            if any(probe["status"] != "passed" for probe in row["model_probes"]):
                raise RuntimeError("one or more first/middle/last model probes failed")
            if all_models and row["all_model_passed_count"] != len(episodes):
                raise RuntimeError("one or more full catalogue episode models failed")
            row["status"] = "passed"
            print("catalog %s %s: %d episodes, first/middle/last models passed" %
                  (runtime, series_id, len(episodes)), flush=True)
        except Exception as error:
            row["error"] = safe_error(error)


def fixture(output, row):
    return {"file": row["file"], "runtime": row["runtime"],
            "series_id": row["series_id"], "episode_id": row["episode_id"],
            "quality": row["quality"], "expected_valid": True,
            "bytes": row["bytes"], "sha256": row["sha256"]}


def make_legacy_fixture(module, output, valid):
    """Reproduce the old bug: overwrite a sinf replacement's *size* with free."""
    source = output / valid["file"]
    data = bytearray(source.read_bytes())
    moov = next(box for box in module._iter_mp4_boxes(data, 0, len(data)) if box["type"] == "moov")
    changed = None
    # Search only sample-entry children; a top-level free is valid padding and
    # corrupting that would not reproduce the invalid stsd/sample entry.
    def entries(parent):
        for box in module._iter_mp4_boxes(data, parent["body"], parent["offset"] + parent["size"]):
            if box["type"] in ("trak", "mdia", "minf", "stbl"):
                yield from entries(box)
            elif box["type"] == "stsd":
                yield from module._iter_mp4_boxes(data, box["body"] + 8, box["offset"] + box["size"])
    for entry in entries(moov):
        if entry["type"] not in ("hvc1", "hev1", "avc1", "avc3"):
            continue
        for child in module._iter_mp4_boxes(data, entry["body"] + 78, entry["offset"] + entry["size"]):
            if child["type"] == "free":
                changed = child["offset"]
                data[changed:changed + 4] = b"free"
                break
        if changed is not None:
            break
    if changed is None:
        raise RuntimeError("could not find a sample-entry free child for legacy control")
    target = output / "legacy" / (source.stem + ".legacy.mp4")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    if module._verify_mp4(str(target)):
        raise RuntimeError("legacy malformed sample unexpectedly passed structural verification")
    return {**valid, "file": str(target.relative_to(output)), "expected_valid": False,
            "expected_invalid": True, "bytes": len(data), "sha256": sha256(target),
            "corruption": "sample-entry free child size overwritten with ASCII free",
            "corruption_offset": changed, "derived_from": valid["file"]}


def acquire(args, output, report, temp):
    budget = ByteBudget(output, int(args.max_total_mb * 1024 * 1024))
    node = NodeAdapter(temp, output, budget) if "node" in args.runtimes else None
    # Node decryption reuses py105's encrypted CDN response, so that adapter must
    # also run when Node is selected by itself.
    runtimes = list(dict.fromkeys((["py105"] if node else []) + args.runtimes))
    runtimes = [runtime for runtime in runtimes if runtime != "node"]
    for runtime in runtimes:
        module = load_adapter(runtime, output, budget)
        models = {}
        if not args.skip_catalog:
            verify_catalog(module, runtime, report, models, args.catalog_all_models,
                           node if runtime == "py105" else None)
        if args.catalog_only:
            continue
        for episode_id in args.episodes:
            model = models.get(episode_id) or module._signed_model(episode_id)
            node_model = node.model(model, args.qualities) if node and runtime == "py105" and model else None
            for quality in args.qualities:
                row = {"runtime": runtime, "series_id": EPISODES[episode_id],
                       "episode_id": episode_id, "quality": quality, "status": "failed"}
                report["samples"].append(row)
                node_row = None
                if node and runtime == "py105":
                    node_row = {**row, "runtime": "node", "acquisition_runtime": "py105",
                                "provenance": "same encrypted CDN bytes; independent Node CENC decryption"}
                    report["samples"].append(node_row)
                started = time.monotonic()
                try:
                    if not model:
                        raise RuntimeError("signed API returned no model")
                    row.update(model_summary(module, model))
                    selected = module._pick_best(model, quality)
                    if not selected:
                        row.update(status="unavailable", reason="requested quality absent or incompatible in live model")
                        if node_row is not None:
                            if node_model["selected"][quality] is not None:
                                raise RuntimeError("Python and Node disagree about unavailable quality")
                            node_row.update(status="unavailable", reason=row["reason"],
                                            offered_qualities=node_model["offered"])
                        print("%s %s %s: unavailable" % (runtime, episode_id, quality), flush=True)
                        continue
                    if selected[1] != quality:
                        raise RuntimeError("adapter silently selected a different quality")
                    if node_row is not None and node_model["selected"][quality] != quality:
                        raise RuntimeError("Node did not select exact advertised quality")
                    metadata = module._video_metadata(selected[0])
                    row.update(selected_quality=selected[1], encrypted=module._is_encrypted(selected[0]),
                               source_width=metadata.get("vwidth"), source_height=metadata.get("vheight"))
                    original_decrypt = module._cenc_decrypt
                    if node_row is not None:
                        def decrypt_both(src, dst, key):
                            try:
                                original_decrypt(src, dst, key)
                            finally:
                                try:
                                    node.decrypt(src, key, episode_id, quality)
                                except Exception as error:
                                    node.results[(episode_id, quality)] = {"status": "failed", "error": safe_error(error)}
                        module._cenc_decrypt = decrypt_both
                        # Force a real decryption on reruns, too. Existing files
                        # are never accepted as evidence for a new source tree.
                        for target in (output / runtime / "media" / (episode_id + "_" + quality + ".mp4"),
                                       output / "node/media" / (episode_id + "_" + quality + ".mp4")):
                            target.unlink(missing_ok=True)
                    else:
                        (output / runtime / "media" / (episode_id + "_" + quality + ".mp4")).unlink(missing_ok=True)
                    try:
                        path = module._decrypt_to_file(episode_id, quality)
                    finally:
                        module._cenc_decrypt = original_decrypt
                    if not path or not module._verify_mp4(path):
                        raise RuntimeError("adapter failed to produce a structurally valid clear MP4")
                    path = Path(path)
                    row.update(status="passed", file=str(path.relative_to(output)),
                               bytes=path.stat().st_size, sha256=sha256(path),
                               elapsed_seconds=round(time.monotonic() - started, 3),
                               decryption_path="python-cenc-no-ffmpeg")
                    report["fixtures"].append(fixture(output, row))
                    print("%s %s %s: passed (%d bytes)" % (runtime, episode_id, quality, row["bytes"]), flush=True)
                except Exception as error:
                    row.update(status="failed", error=safe_error(error))
                    print("%s %s %s: failed (%s)" % (runtime, episode_id, quality, type(error).__name__), flush=True)
                finally:
                    if node_row is not None and node_row["status"] != "unavailable":
                        result = node.results.pop((episode_id, quality), None)
                        if result:
                            node_row.update(result)
                        else:
                            node_row.update(status="failed", error={"type": "RuntimeError", "message": "no Node decryption output"})
                        if node_row["status"] == "passed":
                            report["fixtures"].append(fixture(output, node_row))
                    # Failed partial outputs must not enter native validation.
                    for partial in (output / runtime).rglob("*.tmp.mp4"):
                        partial.unlink(missing_ok=True)
                    for partial in (output / runtime).rglob("*.enc.mp4"):
                        partial.unlink(missing_ok=True)
    report["downloaded_bytes"] = budget.downloaded
    if not args.catalog_only and not args.no_legacy_fixture and report["fixtures"]:
        first = next((item for item in report["fixtures"] if item["runtime"] == "py105"), report["fixtures"][0])
        budget.ensure(first["bytes"])
        module = load_adapter("py105", output, budget)
        report["fixtures"].append(make_legacy_fixture(module, output, first))
    report["output_media_bytes"] = output_bytes(output)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="directory for MP4 fixtures and report.json")
    parser.add_argument("--runtimes", default="py105,py104,node", help="comma-separated py105,py104,node")
    parser.add_argument("--episodes", default=",".join(DEFAULT_EPISODES), help="comma-separated IDs from the three logged targets")
    parser.add_argument("--qualities", default=",".join(QUALITIES), help="comma-separated exact qualities; unavailable entries are recorded")
    parser.add_argument("--max-total-mb", type=float, default=512, help="maximum media output MiB, including temporary files (default: 512)")
    parser.add_argument("--catalog-only", action="store_true", help="check series counts and first/middle/last models without downloading MP4s")
    parser.add_argument("--catalog-all-models", action="store_true", help="also resolve all 515 catalogue episode models in signed API batches of 10; no additional MP4s")
    parser.add_argument("--skip-catalog", action="store_true", help="omit series catalogue checks for a targeted download rerun")
    parser.add_argument("--no-legacy-fixture", action="store_true", help="omit deliberately malformed .legacy.mp4 control")
    args = parser.parse_args(argv)
    for option, allowed in (("runtimes", {*SOURCES, "node"}), ("episodes", set(EPISODES)), ("qualities", set(QUALITIES))):
        value = list(dict.fromkeys(getattr(args, option).split(",")))
        if not value or any(item not in allowed for item in value):
            parser.error("--%s must contain only %s" % (option, ",".join(sorted(allowed))))
        setattr(args, option, value)
    if args.max_total_mb <= 0:
        parser.error("--max-total-mb must be positive")
    if args.skip_catalog and args.catalog_only:
        parser.error("--catalog-only cannot be combined with --skip-catalog")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    report = {"schema_version": 1, "started_at": datetime.now(timezone.utc).isoformat(),
              "online": True, "ffmpeg_disabled": True, "runtimes": args.runtimes,
              "episodes": args.episodes, "qualities": args.qualities,
              "catalog_only": args.catalog_only, "catalog_all_models": args.catalog_all_models,
              "catalogs": [], "samples": [], "fixtures": [],
              "source_sha256": {runtime: sha256(path) for runtime, path in
                                {**SOURCES, "node": ROOT / "Examples/hgtv-node/hgtv.js"}.items()}}
    started = time.monotonic()
    try:
        with tempfile.TemporaryDirectory(prefix="hgtv-live-matrix-") as temp:
            acquire(args, output, report, temp)
    except Exception as error:
        report["error"] = safe_error(error)
    failed = [row for row in report["catalogs"] + report["samples"] if row["status"] == "failed"]
    report.update(passed=not failed and "error" not in report,
                  failed_count=len(failed), elapsed_seconds=round(time.monotonic() - started, 3),
                  finished_at=datetime.now(timezone.utc).isoformat())
    (output / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"report": str(output / "report.json"), "passed": report["passed"],
                      "failed_count": len(failed), "fixture_count": len(report["fixtures"])}), flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
