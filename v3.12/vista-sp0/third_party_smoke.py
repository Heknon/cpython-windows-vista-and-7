"""Functional smoke tests for the validation-only third-party package matrix."""

import importlib.metadata
import os
from pathlib import Path
import site
import sys
import tempfile


package_root = Path(sys.executable).resolve().parent
validation_site = package_root / "validation-packages"
if not validation_site.is_dir():
    raise AssertionError("validation-packages is missing")

# The embeddable interpreter intentionally omits site initialization.  Add the
# validation directory explicitly so its .pth bootstraps, including pywin32's
# private-DLL setup, execute exactly as they do in an assembled application.
site.addsitedir(str(validation_site))

expected_versions = {
    "plumbum": "1.9.0",
    "psutil": "7.0.0",
    "rpyc": "6.0.2",
}
if sys.maxsize <= 2**32:
    expected_versions["pywin32"] = "307"
for distribution, expected in expected_versions.items():
    actual = importlib.metadata.version(distribution)
    if actual != expected:
        raise AssertionError(
            f"{distribution} version mismatch: expected {expected}, got {actual}"
        )

def test_pywin32():
    # Exercise several independent native extensions and their shared
    # pywintypes/pythoncom DLLs, not just top-level imports.
    import pythoncom
    import win32api
    import win32con
    import win32event
    import win32file
    import win32security

    if win32api.GetCurrentProcessId() != os.getpid():
        raise AssertionError("pywin32 returned the wrong process ID")

    event = win32event.CreateEvent(None, True, False, None)
    try:
        win32event.SetEvent(event)
        if win32event.WaitForSingleObject(event, 0) != win32event.WAIT_OBJECT_0:
            raise AssertionError("pywin32 event did not become signaled")
    finally:
        event.Close()

    payload = b"vista-third-party-package-smoke"
    with tempfile.TemporaryDirectory() as directory:
        path = str(Path(directory, "pywin32-round-trip.bin"))
        handle = win32file.CreateFile(
            path,
            win32con.GENERIC_READ | win32con.GENERIC_WRITE,
            0,
            None,
            win32con.CREATE_ALWAYS,
            win32con.FILE_ATTRIBUTE_NORMAL,
            None,
        )
        try:
            _, written = win32file.WriteFile(handle, payload)
            if written != len(payload):
                raise AssertionError("pywin32 did not write the complete payload")
            win32file.SetFilePointer(handle, 0, win32con.FILE_BEGIN)
            _, received = win32file.ReadFile(handle, len(payload))
            if received != payload:
                raise AssertionError("pywin32 file round trip failed")
        finally:
            handle.Close()

    token = win32security.OpenProcessToken(
        win32api.GetCurrentProcess(), win32con.TOKEN_QUERY
    )
    token.Close()
    pythoncom.CoInitialize()
    try:
        pythoncom.CreateBindCtx(0)
    finally:
        pythoncom.CoUninitialize()


if sys.maxsize <= 2**32:
    test_pywin32()
else:
    try:
        importlib.metadata.version("pywin32")
    except importlib.metadata.PackageNotFoundError:
        pass
    else:
        raise AssertionError("the Vista-incompatible x64 pywin32 wheel was packaged")

# psutil: calls below cross several process, memory, CPU, disk, and networking
# native paths.  This catches extensions that import successfully but fail as
# soon as a real Windows API is invoked.
import psutil  # noqa: E402

process = psutil.Process()
if process.pid != os.getpid():
    raise AssertionError("psutil returned the wrong process ID")
if not process.name():
    raise AssertionError("psutil returned an empty process name")
process.memory_info()
process.cpu_times()
if psutil.cpu_count() is None or psutil.cpu_count() < 1:
    raise AssertionError("psutil returned an invalid CPU count")
if psutil.virtual_memory().total <= 0:
    raise AssertionError("psutil returned an invalid memory total")
psutil.disk_partitions(all=True)
psutil.net_if_addrs()

# RPyC remains transport-neutral in this PR.  Exercise its actual protocol
# serializer and dependency surface without introducing a VMCI or application
# integration test.
import plumbum  # noqa: E402,F401
import rpyc  # noqa: E402,F401
from rpyc.core import brine  # noqa: E402

message = (None, True, 42, 3.5, "vista", b"rpyc", (1, 2, 3))
if brine.load(brine.dump(message)) != message:
    raise AssertionError("RPyC brine protocol round trip failed")

print("Third-party validation package smoke tests passed.")
