import os
import sys

import rtm_preflight

windows = sys.getwindowsversion()
rtm_versions = {
    (6, 0, 6000): "Windows Vista RTM",
    (6, 1, 7600): "Windows 7 RTM",
}
identity = (windows.major, windows.minor, windows.build)
if identity not in rtm_versions:
    raise AssertionError(
        "guest validation requires Vista RTM (6.0.6000) or "
        f"Windows 7 RTM (6.1.7600), got {identity}"
    )

# Compare every native import with the exports on this exact clean RTM guest
# before importing any of the extension modules.
root = os.path.dirname(os.path.abspath(sys.executable))
rtm_preflight.validate_package(root)

import json  # noqa: E402
import hashlib  # noqa: E402
from pathlib import Path  # noqa: E402
import platform  # noqa: E402
import subprocess  # noqa: E402

root = Path(root)
manifest_path = root / "ARTIFACT-MANIFEST.json"
if not manifest_path.is_file():
    raise AssertionError("ARTIFACT-MANIFEST.json is missing")

with manifest_path.open("r", encoding="utf-8-sig") as stream:
    manifest = json.load(stream)
if manifest.get("python") != "3.12.10":
    raise AssertionError("artifact manifest has the wrong Python version")

for entry in manifest.get("files", ()):
    relative = Path(entry["path"])
    if relative.is_absolute() or ".." in relative.parts:
        raise AssertionError(f"unsafe manifest path: {entry['path']!r}")
    path = root / relative
    if not path.is_file():
        raise AssertionError(f"manifest file is missing: {relative}")
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    if digest.hexdigest() != entry["sha256"]:
        raise AssertionError(f"manifest hash mismatch: {relative}")

# Importing the packaged script executes the full native-module and functional
# smoke suite before the success evidence below is emitted.
import smoke_test  # noqa: E402,F401

regression = os.path.join(root, "rtm_regression.py")
completed = subprocess.run(
    [sys.executable, "-I", regression],
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    text=True,
)
if completed.returncode:
    raise AssertionError(
        "RTM CPython regression groups failed:\n" + completed.stdout
    )
print(completed.stdout, end="")

result = {
    "event": "rtm-guest-validation-passed",
    "os": rtm_versions[identity],
    "windows_version": list(identity),
    "architecture": platform.machine(),
    "python_bits": 64 if sys.maxsize > 2**32 else 32,
    "python_executable": str(Path(sys.executable).resolve()),
    "pid": os.getpid(),
}
print(json.dumps(result, sort_keys=True))
