"""CCTVHost's in-process FFmpeg library access for embedded Python.

This module uses the FFmpeg libraries already linked into the iOS application.
It does not provide or launch an ffmpeg command-line executable.
"""
import json
import builtins

_native_call = getattr(builtins, "_cctvhost_ffmpeg_call", None)


class FFmpegError(RuntimeError):
    """Native FFmpeg could not inspect the requested media."""


def _call(payload):
    if not callable(_native_call):
        raise FFmpegError("CCTVHost native FFmpeg library is unavailable")
    try:
        raw = _native_call(json.dumps(payload, ensure_ascii=False,
                                      separators=(",", ":")))
        result = json.loads(raw)
    except Exception as error:
        raise FFmpegError(str(error)) from error
    if not isinstance(result, dict):
        raise FFmpegError("invalid native FFmpeg response")
    return result


def capabilities():
    """Return the bundled native library versions and decoder availability."""
    return _call({"operation": "capabilities"})


def available():
    """Whether the in-process FFmpeg libraries are available in this build."""
    try:
        return bool(capabilities().get("native_library"))
    except FFmpegError:
        return False


def probe(url, headers=None, timeout=12):
    """Inspect a local file or HTTP(S) stream without launching a process.

    Returns whether the media has video/audio streams and the selected stream
    indices. ``timeout`` (1–30 seconds) sets the maximum FFmpeg I/O wait; format
    probing is capped at 2 MiB and 256 packets, with 5 seconds of stream analysis.
    """
    if not isinstance(url, str) or not url or len(url) > 4096:
        raise ValueError("url must be non-empty text of at most 4096 characters")
    if headers is None:
        headers = {}
    if not isinstance(headers, dict) or len(headers) > 64:
        raise ValueError("headers must be a dictionary with at most 64 entries")
    safe_headers = {}
    for key, value in headers.items():
        if not isinstance(key, str) or not isinstance(value, str):
            raise ValueError("header names and values must be text")
        if (not key or len(key) > 128 or len(value) > 4096 or
                any(not (char.isalnum() or char == "-") for char in key) or
                "\r" in value or "\n" in value):
            raise ValueError("invalid playback header")
        safe_headers[key] = value
    if isinstance(timeout, bool) or not isinstance(timeout, (int, float)):
        raise ValueError("timeout must be a number from 1 to 30 seconds")
    if not 1 <= timeout <= 30:
        raise ValueError("timeout must be from 1 to 30 seconds")
    return _call({"operation": "probe", "url": url,
                  "headers": safe_headers, "timeout": float(timeout)})
