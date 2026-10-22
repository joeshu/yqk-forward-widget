"""Small runtime-layout checks shared by CI and Linux unit tests."""
from __future__ import annotations

import os
from pathlib import Path
import sys

REQUIRED_EXTENSIONS = ("_ssl", "_socket", "_hashlib", "select", "_struct")


def runtime_paths(home: os.PathLike[str] | str, version: str = "3.13") -> tuple[Path, Path]:
    root = Path(home)
    stdlib = root / "lib" / f"python{version}"
    dynload = stdlib / "lib-dynload"
    missing = [str(path) for path in (stdlib, dynload) if not path.is_dir()]
    if missing:
        raise RuntimeError("CPython runtime missing required directories: " + ", ".join(missing))
    extensions = {p.name.split(".")[0] for pattern in ("*.so", "*.fwork") for p in dynload.glob(pattern)}
    absent = [name for name in REQUIRED_EXTENSIONS if name not in extensions]
    if absent:
        raise RuntimeError("CPython device extension modules missing: " + ", ".join(absent))
    return stdlib, dynload


def configure(home: os.PathLike[str] | str, script: os.PathLike[str] | str,
              port: int, data_dir: os.PathLike[str] | str, *, version: str = "3.13") -> None:
    """Set explicit paths and argv; writer must already be installed by the host."""
    stdlib, dynload = runtime_paths(home, version)
    script_path = Path(script).resolve()
    sys.path[:] = [str(script_path.parent), str(stdlib), str(dynload)]
    sys.argv[:] = [str(script_path), "--bind", "127.0.0.1", "--no-engine",
                   "--data-dir", str(Path(data_dir))]
    os.environ["YSP_DATA_DIR"] = str(Path(data_dir))
    ca_file = Path(home) / "ssl" / "cert.pem"
    if not ca_file.is_file():
        raise RuntimeError(f"CPython CA bundle missing: {ca_file}")
    os.environ["SSL_CERT_FILE"] = str(ca_file)
    os.environ["SSL_CERT_DIR"] = ""
    # Port is supplied as argv[1] only if the script's parser requires positional port.
    if port:
        sys.argv[1:1] = [str(port)]


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Validate embedded iOS CPython bundle layout")
    parser.add_argument("--validate", metavar="PYTHON_HOME", required=True)
    parser.add_argument("--version", default="3.13")
    args = parser.parse_args()
    stdlib, dynload = runtime_paths(args.validate, args.version)
    ca = Path(args.validate) / "ssl" / "cert.pem"
    if not ca.is_file() or ca.stat().st_size == 0:
        raise SystemExit(f"ERROR: missing or empty CA bundle: {ca}")
    print(f"CPython runtime OK: stdlib={stdlib}; device extensions={dynload}; CA={ca}")
