import json
import os
from pathlib import Path
import platform
import sys


root = Path(sys.executable).resolve().parent
manifest_path = root / "ARTIFACT-MANIFEST.json"
if not manifest_path.is_file():
    raise AssertionError("ARTIFACT-MANIFEST.json is missing")

with manifest_path.open("r", encoding="utf-8-sig") as stream:
    manifest = json.load(stream)
if manifest.get("python") != "3.12.10":
    raise AssertionError("artifact manifest has the wrong Python version")

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

# Importing the packaged script executes the full native-module and functional
# smoke suite before the success evidence below is emitted.
import smoke_test  # noqa: E402,F401

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
