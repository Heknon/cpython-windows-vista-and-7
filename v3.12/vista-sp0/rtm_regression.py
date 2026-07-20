"""Run the CPython regression groups most exposed to the RTM backport."""

import os
import subprocess
import sys


root = os.path.dirname(os.path.abspath(sys.executable))
validation_lib = os.path.join(root, "validation-lib")
if not os.path.isdir(os.path.join(validation_lib, "test")):
    raise AssertionError("the packaged CPython regression suite is missing")
sys.path.insert(0, validation_lib)

from test.libregrtest.main import main as run_regrtest  # noqa: E402


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

def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--single":
        test_name = sys.argv[2]
        if test_name not in TESTS:
            raise AssertionError(f"unknown RTM regression group: {test_name}")
        sys.argv[:] = [sys.argv[0]]
        # An embeddable ._pth configuration intentionally ignores PYTHON*
        # environment variables.  The normal and -X dev debug paths remain
        # covered, but upstream's environment-variable cases do not describe
        # this distribution's supported semantics.
        run_regrtest(
            tests=[test_name],
            _add_python_opts=False,
            timeout=300,
            match_tests=[("*test_env_var_debug", False)],
        )

    if len(sys.argv) != 1:
        raise AssertionError(f"unexpected RTM regression arguments: {sys.argv[1:]!r}")

    failures = []
    for test_name in TESTS:
        print(f"RTM regression starting: {test_name}", flush=True)
        try:
            completed = subprocess.run(
                [sys.executable, __file__, "--single", test_name],
                timeout=420,
            )
        except subprocess.TimeoutExpired:
            failures.append(f"{test_name} exceeded seven minutes")
            print(f"RTM regression timed out: {test_name}", flush=True)
            continue
        if completed.returncode:
            failures.append(f"{test_name} exited {completed.returncode}")
            print(f"RTM regression failed: {test_name}", flush=True)
            continue
        print(f"RTM regression passed: {test_name}", flush=True)

    if failures:
        raise AssertionError("RTM regression failures: " + ", ".join(failures))


if __name__ == "__main__":
    main()
