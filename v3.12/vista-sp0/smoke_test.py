import asyncio
import bz2
import ctypes
import decimal
import hashlib
import importlib
import json
import lzma
import mmap
import multiprocessing
import os
from pathlib import Path
import platform
import shutil
import socket
import stat
import sqlite3
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import xml.etree.ElementTree as element_tree


EXPECTED = (3, 12, 10)
if sys.version_info[:3] != EXPECTED:
    raise AssertionError(f"expected Python {EXPECTED}, got {sys.version_info[:3]}")

package_root = Path(sys.executable).resolve().parent
native_modules = sorted(path.stem.split(".", 1)[0] for path in package_root.glob("*.pyd"))
if not native_modules:
    raise AssertionError("the package contains no native extension modules")
for name in native_modules:
    importlib.import_module(name)

payload = b"vista-sp0-compatibility-smoke-test"
if bz2.decompress(bz2.compress(payload)) != payload:
    raise AssertionError("bz2 round trip failed")
if lzma.decompress(lzma.compress(payload)) != payload:
    raise AssertionError("lzma round trip failed")
if hashlib.sha256(payload).hexdigest() != "b91264e75bf776dd5b113a11466a8e302203c7c4231b64629a8a13d756f20f99":
    raise AssertionError("hashlib result is incorrect")
if decimal.Decimal("1.25") * 4 != 5:
    raise AssertionError("decimal arithmetic failed")
if element_tree.fromstring("<root><child /></root>").find("child") is None:
    raise AssertionError("ElementTree parsing failed")

with tempfile.TemporaryDirectory() as directory:
    test_file = Path(directory, "round-trip.txt")
    test_file.write_text("vista-sp0", encoding="utf-8")
    if test_file.read_text(encoding="utf-8") != "vista-sp0":
        raise AssertionError("file round trip failed")

    source = Path(directory, "copy-source.bin")
    source.write_bytes(payload)
    source.chmod(stat.S_IREAD)
    copied = Path(directory, "shutil-copy.bin")
    shutil.copy(source, copied)
    if copied.read_bytes() != payload:
        raise AssertionError("shutil.copy content mismatch")
    if copied.stat().st_mode & stat.S_IWRITE:
        raise AssertionError("shutil.copy did not preserve the read-only mode")
    source.chmod(stat.S_IREAD | stat.S_IWRITE)
    copied.chmod(stat.S_IREAD | stat.S_IWRITE)

    expected_mtime = 946684800
    os.utime(source, (expected_mtime, expected_mtime))
    copied_with_metadata = Path(directory, "shutil-copy2.bin")
    shutil.copy2(source, copied_with_metadata)
    if copied_with_metadata.read_bytes() != payload:
        raise AssertionError("shutil.copy2 content mismatch")
    if abs(copied_with_metadata.stat().st_mtime - expected_mtime) > 2:
        raise AssertionError("shutil.copy2 did not preserve the modification time")

    tree_source = Path(directory, "tree-source")
    tree_source.mkdir()
    Path(tree_source, "nested").mkdir()
    Path(tree_source, "nested", "payload.bin").write_bytes(payload)
    tree_copy = Path(directory, "tree-copy")
    shutil.copytree(tree_source, tree_copy)
    if Path(tree_copy, "nested", "payload.bin").read_bytes() != payload:
        raise AssertionError("shutil.copytree content mismatch")

with sqlite3.connect(":memory:") as connection:
    connection.execute("create table test(value text)")
    connection.execute("insert into test values (?)", ("vista-sp0",))
    if connection.execute("select value from test").fetchone() != ("vista-sp0",):
        raise AssertionError("SQLite round trip failed")

ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
kernel32 = ctypes.windll.kernel32
if kernel32.GetCurrentProcessId() != os.getpid():
    raise AssertionError("ctypes Win32 call failed")

# Exercise both _ctypes default loader modes. A bare DLL name uses
# LOAD_LIBRARY_SEARCH_DEFAULT_DIRS, while an absolute path also requests
# LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR. Neither flag exists before KB2533623.
kernel32_path = os.path.join(os.environ["SystemRoot"], "System32", "kernel32.dll")
kernel32_by_path = ctypes.WinDLL(kernel32_path)
if kernel32_by_path.GetCurrentProcessId() != os.getpid():
    raise AssertionError("ctypes absolute-path Win32 call failed")

compatibility_dll = package_root / "api-ms-win-core-path-l1-1-0.dll"
if not compatibility_dll.is_file():
    raise AssertionError("the DLL-directory probe dependency is missing")

# Verify that multiple DLL directories work together, may be removed out of
# insertion order, and stop participating in searches after close(). This
# exercises the native API on updated Windows and the PATH-backed compatibility
# implementation on Vista/Windows 7 RTM.
with tempfile.TemporaryDirectory() as first_directory, \
        tempfile.TemporaryDirectory() as second_directory:
    first_name = "python_legacy_dll_directory_first.dll"
    second_name = "python_legacy_dll_directory_second.dll"
    remaining_name = "python_legacy_dll_directory_remaining.dll"
    removed_name = "python_legacy_dll_directory_removed.dll"
    shutil.copy2(compatibility_dll, Path(first_directory, first_name))
    shutil.copy2(compatibility_dll, Path(second_directory, second_name))
    shutil.copy2(compatibility_dll, Path(second_directory, remaining_name))
    shutil.copy2(compatibility_dll, Path(second_directory, removed_name))

    first_cookie = os.add_dll_directory(first_directory)
    second_cookie = os.add_dll_directory(second_directory)
    try:
        ctypes.WinDLL(first_name)
        ctypes.WinDLL(second_name)
        first_cookie.close()
        first_cookie = None
        ctypes.WinDLL(remaining_name)
    finally:
        if first_cookie is not None:
            first_cookie.close()
        second_cookie.close()

    try:
        ctypes.WinDLL(removed_name)
    except OSError:
        pass
    else:
        raise AssertionError("a closed DLL directory remained searchable")

# Reproduce the pywin32 startup pattern: a .pth file imports a bootstrap
# module, which adds a DLL directory and immediately loads a dependency from
# it. site.py reports .pth exceptions without failing the interpreter, so the
# child explicitly re-imports the bootstrap and checks its completion marker.
with tempfile.TemporaryDirectory() as directory:
    site_directory = Path(directory, "site-packages")
    dll_directory = Path(directory, "pywin32_system32")
    site_directory.mkdir()
    dll_directory.mkdir()
    probe_name = "python_legacy_pth_dll_directory.dll"
    shutil.copy2(compatibility_dll, dll_directory / probe_name)
    Path(site_directory, "legacy_dll_bootstrap.py").write_text(
        "import ctypes\n"
        "import os\n"
        f"os.add_dll_directory({str(dll_directory)!r})\n"
        f"ctypes.WinDLL({probe_name!r})\n"
        "completed = True\n",
        encoding="utf-8",
    )
    Path(site_directory, "legacy_dll_bootstrap.pth").write_text(
        "import legacy_dll_bootstrap\n",
        encoding="utf-8",
    )
    site_script = (
        "import site; "
        f"site.addsitedir({str(site_directory)!r}); "
        "import legacy_dll_bootstrap; "
        "assert legacy_dll_bootstrap.completed"
    )
    subprocess.run(
        [sys.executable, "-I", "-c", site_script],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

with tempfile.TemporaryFile() as mapped_file:
    mapped_file.write(b"\0" * 4096)
    mapped_file.flush()
    with mmap.mmap(mapped_file.fileno(), 4096) as mapping:
        mapping[:len(payload)] = payload
        if mapping[:len(payload)] != payload:
            raise AssertionError("mmap round trip failed")

started = time.monotonic()
time.sleep(0.01)
if time.monotonic() < started:
    raise AssertionError("monotonic clock moved backwards")

pipe_reader, pipe_writer = multiprocessing.Pipe(duplex=False)
try:
    pipe_writer.send_bytes(payload)
    if pipe_reader.recv_bytes() != payload:
        raise AssertionError("multiprocessing pipe round trip failed")
finally:
    pipe_reader.close()
    pipe_writer.close()

thread_result = []
thread = threading.Thread(target=lambda: thread_result.append("ok"))
thread.start()
thread.join(10)
if thread.is_alive() or thread_result != ["ok"]:
    raise AssertionError("thread test failed")

child = subprocess.run(
    [sys.executable, "-I", "-c", "import sys; print(sys.version_info[:3])"],
    check=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    timeout=30,
)
if "(3, 12, 10)" not in child.stdout:
    raise AssertionError(f"subprocess returned unexpected output: {child.stdout!r}")

listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
listener.settimeout(10)
listener.bind(("127.0.0.1", 0))
listener.listen(1)
client = socket.create_connection(listener.getsockname(), timeout=10)
server, _ = listener.accept()
try:
    client.sendall(payload)
    if server.recv(len(payload)) != payload:
        raise AssertionError("TCP loopback round trip failed")
finally:
    server.close()
    client.close()
    listener.close()

async def async_check():
    await asyncio.sleep(0)
    return "ok"

if asyncio.run(async_check()) != "ok":
    raise AssertionError("asyncio test failed")

print(json.dumps({
    "event": "smoke-test-passed",
    "python": sys.version,
    "platform": platform.platform(),
    "pid": os.getpid(),
    "native_modules": native_modules,
}, sort_keys=True))
