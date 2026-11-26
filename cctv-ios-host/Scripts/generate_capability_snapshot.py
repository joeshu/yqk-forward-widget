#!/usr/bin/env python3
"""Generate the build-specific capability snapshot (T11).

The snapshot is the single machine-readable record of what this build claims
it can play, per format group and per engine, on four levels:

  recognizable    能识别：the descriptor/router can identify the format.
  creatable       能创建：the factory can build an engine for it (route exists
                  and the engine is available/enabled).
  presentable     能呈现：there is a real render path (first frame / audio-only
                  handling, T08) — source-level, not device proof.
  device_verified 已在对应设备验证：only true with a device-evidence record
                  whose build + commit match this snapshot. Without
                  --device-evidence, NOTHING is marked verified: a contract
                  test passing is not device verification (audit §1).

Usage:
  python3 Scripts/generate_capability_snapshot.py [--out PATH]
  python3 Scripts/generate_capability_snapshot.py --check
  python3 Scripts/generate_capability_snapshot.py --device-evidence EVIDENCE.json

--version/--build override the version stamped into the snapshot (CI passes
the values it stamped into the IPA). Otherwise the fallback is
Resources/Info.plist, then "unknown" — the source is always recorded, never
fabricated.
"""
import argparse
import json
import plistlib
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCHEMA_VERSION = 1

# Capability groups, from plan §B2 T11. Each engine level is a source-level
# claim with an evidence pointer (file + symbol) that --check validates.
# device_verified is never set here; only --device-evidence can set it.
GROUPS = [
    {
        "id": "core-vod",
        "formats": ["hls", "mp4", "m4a", "flv", "rtmp", "rtmps", "mkv", "webm", "3gp", "dash"],
        "policy": "保留",
        "verification_gate": "T08 的 A01–A03",
        "engines": {
            "av": {"recognizable": True, "creatable": True, "presentable": True,
                   "note": "HLS/MP4/MP3/AAC 走 AVPlayer（MediaCapabilityAvFormats）"},
            "mpv": {"recognizable": True, "creatable": True, "presentable": True,
                    "note": "MPV 已启用时进候选链（AVPlayer→MPV→Cicada）"},
            "cicada": {"recognizable": True, "creatable": True, "presentable": True,
                       "note": "FLV/DASH/MKV/WebM/3GP/RTMP 走 Cicada（MediaCapabilityCicadaFormats）"},
            "cnplayer": {"recognizable": False, "creatable": False, "presentable": False,
                         "note": "CNPlayerSDK 只用于央视授权直播，不用于点播"},
        },
        "evidence": [
            {"file": "Sources/MediaPlaybackDecodeRouter.m", "symbol": "MediaPlaybackDecodeRouteCandidatesForResult"},
            {"file": "Plugins/media-capabilities.json", "symbol": "avFormats"},
        ],
    },
    {
        "id": "unconnected-transports",
        "formats": ["rtsp", "rtsps", "srt", "smb", "udp", "rtp"],
        "policy": "实验（不改底层能力）",
        "verification_gate": "真实 transport 记录结果；缺失时在 snapshot 标记实验/不支持",
        "engines": {
            "av": {"recognizable": True, "creatable": False, "presentable": False,
                   "note": "入口门禁拒绝：transport 不在 networkTransports 内"},
            "mpv": {"recognizable": True, "creatable": False, "presentable": False,
                    "note": "Router 曾有 scheme 识别分支，但门禁先拒绝；不宣称原生支持"},
            "cicada": {"recognizable": True, "creatable": False, "presentable": False,
                       "note": "Cicada 侧 rtsp/srt/smb 只在 MPV 已启用时宣称可播，门禁仍拒绝"},
            "cnplayer": {"recognizable": False, "creatable": False, "presentable": False,
                         "note": "不在 CN 授权直播路径内"},
        },
        "evidence": [
            {"file": "Sources/MediaPlaybackDecodeRouter.m", "symbol": "unsupported_transport"},
            {"file": "Plugins/media-capabilities.json", "symbol": "protocolCapabilities"},
        ],
    },
    {
        "id": "legacy-codecs",
        "formats": ["avi", "wmv", "asf", "rm", "rmvb", "vp8", "vp9", "av1", "h263", "rv"],
        "policy": "B2 解决旧声明不一致",
        "verification_gate": "门禁按 MPV 启用状态判定（T11）；真机播放待验证",
        "engines": {
            "av": {"recognizable": True, "creatable": False, "presentable": False,
                   "note": "AVPlayer 无 avi/asf/rm demuxer，无 wmv/rv 解码器"},
            "mpv": {"recognizable": True, "creatable": True, "presentable": True,
                    "note": "MPV 已启用时门禁放行（MediaCapabilityMPVOnly*）；禁用时拒绝"},
            "cicada": {"recognizable": True, "creatable": False, "presentable": False,
                       "note": "Cicada 无 vp8/vp9 解码器（WebM 只保证容器可解）"},
            "cnplayer": {"recognizable": False, "creatable": False, "presentable": False,
                         "note": "不在 CN 授权直播路径内"},
        },
        "evidence": [
            {"file": "Sources/MediaPlaybackDecodeRouter.m", "symbol": "MediaCapabilityMPVOnlyVideoCodecs"},
            {"file": "Sources/MediaPlaybackDecodeRouter.m", "symbol": "MediaPlaybackDecodeRouteRejectionReasonForResult"},
            {"file": "Sources/MediaCapabilityRegistry.h", "symbol": "MediaCapabilityMPVOnlyContainers"},
        ],
    },
    {
        "id": "cenc-drm",
        "formats": ["cenc"],
        "policy": "仅保留与现有代理/授权有关的路径",
        "verification_gate": "A04：授权失败不做规避",
        "engines": {
            "av": {"recognizable": True, "creatable": True, "presentable": True,
                   "note": "红果 cenc 走本地 127.0.0.1 代理（url 字段为准，不查 originalURL）"},
            "mpv": {"recognizable": False, "creatable": False, "presentable": False,
                    "note": "CENC 代理路径只接 AV 链路"},
            "cicada": {"recognizable": False, "creatable": False, "presentable": False,
                       "note": "CENC 代理路径只接 AV 链路"},
            "cnplayer": {"recognizable": False, "creatable": False, "presentable": False,
                         "note": "不在 CN 授权直播路径内"},
        },
        "evidence": [
            {"file": "Sources/MediaPlaybackDecodeRouter.m", "symbol": "cenc://"},
        ],
    },
    {
        "id": "encrypted-mp4",
        "formats": ["encrypted-mp4", "segmented-cenc"],
        "policy": "按现有流式代理与加密通道记录",
        "verification_gate": "A04：支持子集可呈现且 seek 与音轨正确",
        "engines": {
            "av": {"recognizable": True, "creatable": True, "presentable": True,
                   "note": "与 cenc-drm 同一代理通道；分段走流式代理"},
            "mpv": {"recognizable": False, "creatable": False, "presentable": False,
                    "note": "未接加密代理通道"},
            "cicada": {"recognizable": False, "creatable": False, "presentable": False,
                       "note": "未接加密代理通道"},
            "cnplayer": {"recognizable": False, "creatable": False, "presentable": False,
                         "note": "不在 CN 授权直播路径内"},
        },
        "evidence": [
            {"file": "Sources/MediaPlaybackDecodeRouter.m", "symbol": "cenc://"},
        ],
    },
    {
        "id": "hdr",
        "formats": ["hdr", "hlg", "dolby-vision"],
        "policy": "只做可识别与降级规则，避免夸大",
        "verification_gate": "识别 + 降级，不宣称全支持",
        "engines": {
            "av": {"recognizable": True, "creatable": True, "presentable": True,
                   "note": "可识别，依系统能力呈现/降级；不宣称逐 profile 全支持"},
            "mpv": {"recognizable": True, "creatable": True, "presentable": True,
                    "note": "可识别，依内核能力呈现/降级；不宣称逐 profile 全支持"},
            "cicada": {"recognizable": True, "creatable": False, "presentable": False,
                       "note": "未做 HDR 逐 profile 声明"},
            "cnplayer": {"recognizable": False, "creatable": False, "presentable": False,
                         "note": "不在 CN 授权直播路径内"},
        },
        "evidence": [
            {"file": "Sources/MediaPlaybackDecodeRouter.m", "symbol": "MediaPlaybackDecodeRouteCandidatesForResult"},
        ],
    },
    {
        "id": "pip",
        "formats": ["picture-in-picture"],
        "policy": "只开放已实现的 AV 路径；MPV/Cicada/CN 不宣称",
        "verification_gate": "A07：实际 PiP 视频连续、恢复正确，无双音频",
        "engines": {
            "av": {"recognizable": True, "creatable": True, "presentable": True,
                   "note": "系统 AVPlayerViewController（allowsPictureInPicturePlayback=YES）"},
            "mpv": {"recognizable": True, "creatable": False, "presentable": False,
                    "note": "T10：无供帧，isPictureInPictureSupported 返回 NO；供帧是 T24 的工作"},
            "cicada": {"recognizable": False, "creatable": False, "presentable": False,
                       "note": "未实现 PiP 方法（respondsToSelector 为 NO 即不支持）"},
            "cnplayer": {"recognizable": False, "creatable": False, "presentable": False,
                         "note": "未实现 PiP"},
        },
        "evidence": [
            {"file": "Sources/MediaPlaybackMPVAdapter.m", "symbol": "isPictureInPictureSupported"},
            {"file": "Sources/MediaPlaybackViewController.m", "symbol": "allowsPictureInPicturePlayback"},
        ],
    },
    {
        "id": "airplay",
        "formats": ["airplay-video", "airplay-audio"],
        "policy": "仅开放已验证的视频外放/音频路由区分，不改加密输出",
        "verification_gate": "A07：电视实际音视频而非 route 图标",
        "engines": {
            "av": {"recognizable": True, "creatable": True, "presentable": True,
                   "note": "视频外放只认 isExternalPlaybackActive；音频路由另行显示（T10）"},
            "mpv": {"recognizable": False, "creatable": False, "presentable": False,
                    "note": "MPV 未见独立视频投屏实现"},
            "cicada": {"recognizable": False, "creatable": False, "presentable": False,
                       "note": "Cicada 未见独立视频投屏实现"},
            "cnplayer": {"recognizable": False, "creatable": False, "presentable": False,
                         "note": "CN 未见独立视频投屏实现"},
        },
        "evidence": [
            {"file": "Sources/RootViewController+Playback.m", "symbol": "isAirPlayVideo"},
        ],
    },
]


def git_head():
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, text=True).strip()
    except Exception:
        return "unknown"


def plist_version():
    try:
        with open(ROOT / "Resources" / "Info.plist", "rb") as f:
            info = plistlib.load(f)
        return (info.get("CFBundleShortVersionString") or "unknown",
                str(info.get("CFBundleVersion") or "unknown"))
    except Exception:
        return "unknown", "unknown"


def check_registry_fresh():
    """Fail unless the generated capability registry matches its JSON source."""
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "gen_caps", ROOT / "Scripts" / "generate_media_capabilities.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    target = ROOT / "Sources" / "MediaCapabilityRegistry.h"
    if not target.exists() or target.read_text() != module.render():
        raise SystemExit("Stale media capability registry: run Scripts/generate_media_capabilities.py")


def check_evidence_pointers(groups):
    for group in groups:
        for ev in group["evidence"]:
            path = ROOT / ev["file"]
            if not path.exists():
                raise SystemExit("Snapshot evidence missing file: %s (group %s)" % (ev["file"], group["id"]))
            if ev["symbol"] not in path.read_text(encoding="utf-8", errors="replace"):
                raise SystemExit("Snapshot evidence stale: %r not in %s (group %s)"
                                 % (ev["symbol"], ev["file"], group["id"]))


def load_device_evidence(path):
    data = json.loads(Path(path).read_text())
    if not isinstance(data, dict) or not isinstance(data.get("groups"), dict):
        raise SystemExit("Device evidence must be {\"groups\": {<group-id>: {...}}}")
    return data["groups"]


def build_snapshot(version, build, version_source, device_evidence):
    registry = json.loads((ROOT / "Plugins" / "media-capabilities.json").read_text())
    groups = []
    applied = 0
    for group in GROUPS:
        engines = {}
        for engine, levels in group["engines"].items():
            engines[engine] = {
                "recognizable": levels["recognizable"],
                "creatable": levels["creatable"],
                "presentable": levels["presentable"],
                "device_verified": False,
                "note": levels["note"],
            }
        record = dict(group)
        record["engines"] = engines
        record["device_verification"] = {
            "status": "pending_device_verification",
            "evidence": None,
        }
        ev = (device_evidence or {}).get(group["id"])
        if ev:
            commit = git_head()
            ev_commit = str(ev.get("commit") or "")
            commit_ok = bool(ev_commit) and (commit.startswith(ev_commit) or ev_commit.startswith(commit))
            if (str(ev.get("version")), str(ev.get("build"))) != (str(version), str(build)) or not commit_ok:
                print("warning: device evidence for %s does not match this build "
                      "(want version=%s build=%s commit=%s, got version=%s build=%s commit=%s); skipped"
                      % (group["id"], ev.get("version"), ev.get("build"), ev_commit, version, build, commit), file=sys.stderr)
            else:
                missing = [k for k in ("device", "media", "date") if not ev.get(k)]
                if missing:
                    raise SystemExit("Device evidence for %s lacks: %s" % (group["id"], ", ".join(missing)))
                for engine in engines:
                    engines[engine]["device_verified"] = bool(ev.get("engines", {}).get(engine, False))
                record["device_verification"] = {"status": "verified", "evidence": ev}
                applied += 1
        groups.append(record)
    return {
        "schema_version": SCHEMA_VERSION,
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "build": {"version": version, "build": build, "commit": git_head(),
                  "version_source": version_source},
        "rules": [
            "device_verified is true only with a device-evidence record whose version+build+commit match this snapshot.",
            "Contract tests passing is not device verification.",
            "A capability with creatable/presentable false must not be shown as supported in UI.",
        ],
        "protocol_capabilities": registry.get("protocolCapabilities", {}),
        "groups": groups,
    }, applied


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default=None)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--device-evidence", default=None)
    parser.add_argument("--version", default=None)
    parser.add_argument("--build", default=None)
    args = parser.parse_args()

    check_registry_fresh()
    check_evidence_pointers(GROUPS)

    pv, pb = plist_version()
    if args.version or args.build:
        version, build, source = args.version or pv, args.build or pb, "cli"
    elif pv != "unknown":
        version, build, source = pv, pb, "Resources/Info.plist"
    else:
        version, build, source = "unknown", "unknown", "unknown"

    device_evidence = load_device_evidence(args.device_evidence) if args.device_evidence else None
    snapshot, applied = build_snapshot(version, build, source, device_evidence)
    if args.device_evidence and applied == 0:
        raise SystemExit("Device evidence supplied but no group matched this build; refusing to certify anything")

    if args.check:
        print("capability snapshot OK: %d groups, %d device-verified, build %s (%s) @ %s"
              % (len(snapshot["groups"]), applied, version, build, snapshot["build"]["commit"]))
        return
    out = Path(args.out) if args.out else ROOT / "capability-snapshot.json"
    out.write_text(json.dumps(snapshot, indent=2, ensure_ascii=False) + "\n")
    print("wrote %s (%d groups, %d device-verified)" % (out, len(snapshot["groups"]), applied))


if __name__ == "__main__":
    main()
