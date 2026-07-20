"""Run the CPython regression groups most exposed to the RTM backport."""

import os
import sys


root = os.path.dirname(os.path.abspath(sys.executable))
validation_lib = os.path.join(root, "validation-lib")
if not os.path.isdir(os.path.join(validation_lib, "test")):
    raise AssertionError("the packaged CPython regression suite is missing")
sys.path.insert(0, validation_lib)

from test.libregrtest.main import main  # noqa: E402


TESTS = (
    "test_asyncio",
    "test_ctypes",
    "test_import",
    "test_importlib",
    "test_mmap",
    "test_multiprocessing_spawn",
    "test_ntpath",
    "test_os",
    "test_shutil",
    "test_socket",
    "test_ssl",
    "test_subprocess",
    "test_time",
    "test_winapi",
    "test_winreg",
)

main(tests=TESTS, _add_python_opts=False)
