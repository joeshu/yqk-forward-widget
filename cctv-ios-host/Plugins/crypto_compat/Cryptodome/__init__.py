"""Alias package for the pycryptodomex-style ``Cryptodome`` namespace."""

from pathlib import Path

__version__ = "cctvhost-compat-2"
__path__ = [str(Path(__file__).resolve().parent.parent / "Crypto")]
