#!/usr/bin/env python3
"""CI packaging gates for the CCTVHost unsigned IPA.

Executed on the macOS build runner *after* ``Scripts/validate_ipa.py`` has
confirmed the bundle is structurally well-formed. These gates enforce three
budgets that protect the installed size, prevent accidental framework
expansion, and guarantee the mpv bridge surface stays stable:

1. **IPA size budget** — the unsigned IPA must stay under a byte budget. The
   default budget is the current ~108.8 MiB build plus a 10 % headroom
   (``108.8 * 1024 * 1024 * 1.10`` ≈ 125.49 MiB). Override with the
   ``CCTV_IPA_SIZE_LIMIT_BYTES`` (preferred) or ``CCTV_IPA_SIZE_LIMIT_MB``
   environment variables.

2. **Framework dynamic-library whitelist** — every ``.framework`` directory
   shipped under ``Payload/*.app/Frameworks/`` must be on an allowlist. The
   default allowlist mirrors the frameworks the full build legitimately
   embeds today: ``CNPlayerSDK``, ``CicadaPlayerSDK``, ``alivcffmpeg``,
   ``CCTVMPVCore``, ``Python`` and ``NodeMobile``. Override with
   ``CCTV_FRAMEWORK_WHITELIST`` (comma-separated).

3. **CCTVMPVCore export-symbol gate** — on the macOS runner ``nm -gU`` must
   report the key ``mpv_`` entry points, proving the dynamic framework still
   exposes its C bridge (and was linked with the exported-symbols list). The
   required subset lives in :data:`REQUIRED_MPV_SYMBOLS`; the full allowlist
   is read from ``Scripts/mpv_exported_symbols.txt`` for reporting only.

No App source code is touched; the script only reads the produced IPA and,
for gate 3, shells out to the system ``nm``. Every gate prints a clear,
single-line summary and, on failure, a GitHub Actions ``::error`` annotation
so the failure is visible in the checks UI. The process exits non-zero if any
gate fails.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path
from typing import Callable, Iterable, List, Optional, Sequence, Tuple

# ----------------------------------------------------------------------------
# Defaults / budgets
# ----------------------------------------------------------------------------

#: Baseline full-build IPA size used to derive the default budget (MiB).
BASELINE_IPA_MIB = 108.8
#: Headroom ratio applied on top of the baseline (10 %).
HEADROOM_RATIO = 0.10


def _default_size_limit_bytes() -> int:
    """Default budget = baseline MiB * 1024^2 * (1 + headroom)."""
    return int(round(BASELINE_IPA_MIB * (1 << 20) * (1.0 + HEADROOM_RATIO)))


#: Frameworks the full build legitimately embeds today. Sourced from
#: ``Scripts/validate_ipa.py`` (CNPlayerSDK / CicadaPlayerSDK / alivcffmpeg /
#: CCTVMPVCore / Python / NodeMobile).
FRAMEWORK_WHITELIST_DEFAULT: Tuple[str, ...] = (
    "CNPlayerSDK",
    "CicadaPlayerSDK",
    "alivcffmpeg",
    "CCTVMPVCore",
    "Python",
    "NodeMobile",
)

#: Key ``mpv_`` entry points that must be exported by CCTVMPVCore. This is a
#: subset of ``Scripts/mpv_exported_symbols.txt``; "at least" these must show
#: up in ``nm -gU`` output.
REQUIRED_MPV_SYMBOLS: Tuple[str, ...] = (
    "_mpv_client_api_version",
    "_mpv_create",
    "_mpv_initialize",
    "_mpv_destroy",
    "_mpv_terminate_destroy",
    "_mpv_set_option_string",
    "_mpv_command",
    "_mpv_set_property",
    "_mpv_get_property",
    "_mpv_get_property_string",
    "_mpv_observe_property",
    "_mpv_wait_event",
    "_mpv_wakeup",
    "_mpv_error_string",
    "_mpv_free",
)

#: Name of the CCTVMPVCore framework binary member inside the IPA.
MPV_FRAMEWORK_NAME = "CCTVMPVCore"

# ----------------------------------------------------------------------------
# Result type
# ----------------------------------------------------------------------------

#: A single gate outcome: ``(gate_name, passed, detail)``.
GateResult = Tuple[str, bool, str]


# ----------------------------------------------------------------------------
# IPA introspection helpers
# ----------------------------------------------------------------------------

def _discover_app_root(namelist: Sequence[str]) -> str:
    """Return the ``Payload/<app>.app/`` prefix from a ZIP namelist.

    Raises ``ValueError`` if no app payload is present, which surfaces as a
    gate failure rather than an obscure IndexError.
    """
    for name in namelist:
        if name.startswith("Payload/") and name.endswith(".app/"):
            return name
    # Fall back to scanning for the first Payload/<x>.app/ component.
    for name in namelist:
        m = re.match(r"^Payload/([^/]+\.app)/", name)
        if m:
            return f"Payload/{m.group(1)}/"
    raise ValueError("no Payload/<app>.app/ root found in IPA")


def _list_frameworks(zf: zipfile.ZipFile, app_root: str) -> List[str]:
    """Return the sorted, de-duplicated framework *names* in the IPA.

    A framework directory is any ``<app_root>Frameworks/<name>.framework/``
    entry; only the directory-style member (trailing slash) is counted so a
    stray file cannot create a false positive.
    """
    prefix = f"{app_root}Frameworks/"
    names = set()
    for member in zf.namelist():
        if not member.startswith(prefix):
            continue
        rest = member[len(prefix):]
        if "/" not in rest:
            continue
        head = rest.split("/", 1)[0]
        if head.endswith(".framework"):
            names.add(head[: -len(".framework")])
    return sorted(names)


def _mpv_binary_member(app_root: str) -> str:
    return f"{app_root}Frameworks/{MPV_FRAMEWORK_NAME}.framework/{MPV_FRAMEWORK_NAME}"


# ----------------------------------------------------------------------------
# Gate 1 — IPA size
# ----------------------------------------------------------------------------

def check_ipa_size(ipa_path: str | os.PathLike, limit_bytes: int) -> GateResult:
    """Verify the on-disk IPA is within ``limit_bytes``."""
    size = os.path.getsize(ipa_path)
    mib = size / (1 << 20)
    limit_mib = limit_bytes / (1 << 20)
    passed = size <= limit_bytes
    if passed:
        detail = (
            f"IPA size {mib:.2f} MiB ({size} B) within budget "
            f"{limit_mib:.2f} MiB ({limit_bytes} B) — {limit_bytes - size} B headroom"
        )
    else:
        detail = (
            f"IPA size {mib:.2f} MiB ({size} B) EXCEEDS budget "
            f"{limit_mib:.2f} MiB ({limit_bytes} B) by {size - limit_bytes} B "
            f"({(size - limit_bytes) / (1 << 20):.2f} MiB)"
        )
    return ("ipa-size", passed, detail)


# ----------------------------------------------------------------------------
# Gate 2 — framework whitelist
# ----------------------------------------------------------------------------

def check_framework_whitelist(
    ipa_path: str | os.PathLike,
    whitelist: Iterable[str],
) -> GateResult:
    """Verify every embedded framework is on the whitelist."""
    allowed = {name for name in whitelist}
    with zipfile.ZipFile(ipa_path) as zf:
        app_root = _discover_app_root(zf.namelist())
        present = _list_frameworks(zf, app_root)
    offenders = [name for name in present if name not in allowed]
    passed = not offenders
    if passed:
        detail = (
            f"frameworks {present} all on whitelist "
            f"({len(allowed)} allowed)"
        )
    else:
        offenders_str = ", ".join(sorted(offenders))
        detail = (
            f"unknown frameworks not on whitelist: [{offenders_str}] "
            f"(allowed: {sorted(allowed)}); present: {present}"
        )
    return ("framework-whitelist", passed, detail)


# ----------------------------------------------------------------------------
# Gate 3 — CCTVMPVCore exported symbols
# ----------------------------------------------------------------------------

def _default_nm_runner(binary_path: str) -> Tuple[int, str, str]:
    """Run ``nm -gU`` on the host (macOS runner) and return (rc, out, err)."""
    proc = subprocess.run(
        ["nm", "-gU", binary_path],
        capture_output=True,
        text=True,
    )
    return proc.returncode, proc.stdout, proc.stderr


def _parse_exported_symbols(nm_stdout: str) -> set:
    """Extract the leading symbol token from each ``nm -gU`` line.

    ``nm -gU`` lines look like ``0000000100000000 T _mpv_create``. We take the
    last whitespace-separated token so address-less / uppercase-type prefixes
    are both handled.
    """
    symbols = set()
    for line in nm_stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        token = line.split()[-1]
        if token.startswith("_"):
            symbols.add(token)
    return symbols


def check_mpv_symbols(
    ipa_path: str | os.PathLike,
    required_symbols: Sequence[str],
    nm_runner: Optional[Callable[[str], Tuple[int, str, str]]] = None,
) -> GateResult:
    """Verify ``nm -gU`` of CCTVMPVCore exposes the required ``mpv_`` symbols.

    ``nm_runner`` is injectable so unit tests can feed fabricated ``nm`` output
    without shelling out. The default runs the real ``nm``.
    """
    runner = nm_runner or _default_nm_runner
    with zipfile.ZipFile(ipa_path) as zf:
        app_root = _discover_app_root(zf.namelist())
        member = _mpv_binary_member(app_root)
        if member not in zf.namelist():
            return (
                "mpv-symbols",
                False,
                f"{MPV_FRAMEWORK_NAME}.framework binary not found in IPA "
                f"({member} absent) — cannot verify exported mpv symbols",
            )
        data = zf.read(member)

    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as tmp:
        tmp_path = tmp.name
        tmp.write(data)
    try:
        rc, out, err = runner(tmp_path)
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass

    if rc != 0:
        return (
            "mpv-symbols",
            False,
            f"nm -gU failed (rc={rc}): {err.strip() or out.strip()[:200]}",
        )

    exported = _parse_exported_symbols(out)
    missing = [s for s in required_symbols if s not in exported]
    mpv_total = sum(1 for s in exported if s.startswith("_mpv_"))
    if missing:
        return (
            "mpv-symbols",
            False,
            f"missing required mpv symbols: {missing} "
            f"(found {mpv_total} _mpv_ exports of {len(exported)} total)",
        )
    return (
        "mpv-symbols",
        True,
        f"CCTVMPVCore exports all {len(required_symbols)} required mpv symbols "
        f"({mpv_total} _mpv_ exports of {len(exported)} total)",
    )


# ----------------------------------------------------------------------------
# Orchestration
# ----------------------------------------------------------------------------

def _resolve_size_limit(env: os._Environ) -> int:
    """Resolve the size budget from env overrides or the computed default."""
    raw_bytes = env.get("CCTV_IPA_SIZE_LIMIT_BYTES")
    if raw_bytes:
        return int(raw_bytes)
    raw_mb = env.get("CCTV_IPA_SIZE_LIMIT_MB")
    if raw_mb:
        return int(round(float(raw_mb) * 1_000_000))
    return _default_size_limit_bytes()


def _resolve_whitelist(env: os._Environ) -> Tuple[str, ...]:
    raw = env.get("CCTV_FRAMEWORK_WHITELIST")
    if raw and raw.strip():
        return tuple(
            name.strip() for name in raw.split(",") if name.strip()
        )
    return FRAMEWORK_WHITELIST_DEFAULT


def run_gates(
    ipa_path: str | os.PathLike,
    *,
    size_limit_bytes: Optional[int] = None,
    whitelist: Optional[Sequence[str]] = None,
    required_mpv_symbols: Sequence[str] = REQUIRED_MPV_SYMBOLS,
    nm_runner: Optional[Callable[[str], Tuple[int, str, str]]] = None,
    env: Optional[os._Environ] = None,
) -> List[GateResult]:
    """Run all three gates and return their results in order."""
    env = env if env is not None else os.environ
    if size_limit_bytes is None:
        size_limit_bytes = _resolve_size_limit(env)
    if whitelist is None:
        whitelist = _resolve_whitelist(env)
    return [
        check_ipa_size(ipa_path, size_limit_bytes),
        check_framework_whitelist(ipa_path, whitelist),
        check_mpv_symbols(ipa_path, required_mpv_symbols, nm_runner),
    ]


# ----------------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------------

def _emit(result: GateResult, stream=sys.stdout) -> None:
    name, passed, detail = result
    status = "PASS" if passed else "FAIL"
    line = f"[ci-gates] {status} {name}: {detail}"
    print(line, file=stream)
    if not passed:
        # GitHub Actions annotation so the failure is visible in the checks UI.
        annotation = detail.replace("%", "%25").replace("\r", "%0D").replace(
            "\n", "%0A"
        ).replace(":", "%3A").replace(",", "%2C")
        print(f"::error title=CI gate {name}::{annotation}", file=stream)


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(
        description="CCTVHost IPA CI packaging gates (size / frameworks / mpv symbols)"
    )
    ap.add_argument("ipa", help="path to the unsigned IPA to gate")
    ap.add_argument(
        "--size-limit-bytes",
        type=int,
        default=None,
        help="IPA size budget in bytes (overrides CCTV_IPA_SIZE_LIMIT_BYTES env)",
    )
    ap.add_argument(
        "--framework-whitelist",
        default=None,
        help="comma-separated framework allowlist (overrides CCTV_FRAMEWORK_WHITELIST env)",
    )
    args = ap.parse_args(argv)

    if not os.path.isfile(args.ipa):
        print(f"[ci-gates] FAIL input: IPA not found: {args.ipa}", file=sys.stderr)
        return 2

    env_whitelist = (
        tuple(s.strip() for s in args.framework_whitelist.split(",") if s.strip())
        if args.framework_whitelist
        else None
    )

    labels = [
        _default_size_limit_bytes() / (1 << 20),
        BASELINE_IPA_MIB,
        HEADROOM_RATIO,
    ]
    print(
        f"[ci-gates] budget basis: baseline {BASELINE_IPA_MIB} MiB * "
        f"(1 + {HEADROOM_RATIO:.0%}) = {labels[0]:.2f} MiB default; "
        "override via CCTV_IPA_SIZE_LIMIT_BYTES / CCTV_IPA_SIZE_LIMIT_MB",
        file=sys.stderr,
    )

    results = run_gates(
        args.ipa,
        size_limit_bytes=args.size_limit_bytes,
        whitelist=env_whitelist,
    )

    for result in results:
        _emit(result)

    failures = [r for r in results if not r[1]]
    if failures:
        print(
            f"[ci-gates] {len(failures)} gate(s) failed: "
            f"{[r[0] for r in failures]}",
            file=sys.stderr,
        )
        return 1
    print("[ci-gates] all gates passed", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
