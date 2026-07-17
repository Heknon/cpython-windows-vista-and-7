import asyncio
import bz2
import ctypes
import decimal
import hashlib
import importlib
import json
import lzma
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
if ctypes.windll.kernel32.GetCurrentProcessId() != os.getpid():
    raise AssertionError("ctypes Win32 call failed")

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
