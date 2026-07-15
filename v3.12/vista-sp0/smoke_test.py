import importlib
import os
import platform
import socket
import sys


EXPECTED = (3, 12, 10)
if sys.version_info[:3] != EXPECTED:
    raise AssertionError(f"expected Python {EXPECTED}, got {sys.version_info[:3]}")

for name in (
    "_asyncio",
    "_ctypes",
    "_multiprocessing",
    "_socket",
    "select",
    "sqlite3",
):
    importlib.import_module(name)

left, right = socket.socketpair()
try:
    left.sendall(b"vista-sp0")
    if right.recv(9) != b"vista-sp0":
        raise AssertionError("socket round trip failed")
finally:
    left.close()
    right.close()

print(
    "smoke test passed:",
    sys.version,
    platform.platform(),
    f"pid={os.getpid()}",
)
