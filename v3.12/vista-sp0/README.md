# Python 3.12.10 for Vista and Windows 7 RTM

This directory contains the build and validation tooling for an embeddable
Python 3.12.10 distribution intended to run on Windows Vista RTM (SP0) and
Windows 7 RTM without KB2533623.

This is an experimental compatibility target. Passing the hosted build and PE
import audit is necessary, but it is not a substitute for testing on clean RTM
virtual machines.

## Compatibility changes

- `patches/0001-pre-kb2533623-dll-loading.patch` is applied before the
  build, leaving the imported Vista fork easy to refresh from upstream.
- `AddDllDirectory` and `RemoveDllDirectory` are resolved with
  `GetProcAddress`, preventing the Windows loader from rejecting
  `python312.dll` when those KB2533623 exports are absent.
- The extension-module loader first uses CPython's restricted modern search
  flags. If and only if Windows returns `ERROR_INVALID_PARAMETER`, it retries
  the absolute module path with `LOAD_WITH_ALTERED_SEARCH_PATH`.
- The build uses the Visual Studio 2015 v140 toolset and replaces the current
  VC runtime with its Vista-compatible VC140 runtime.
- The Universal CRT is included app-locally. The package does not assume that
  the operating system has the UCRT servicing update installed.
- Every packaged PE file is checked for known post-Vista imports.

## Build

Run the **Build Python 3.12 for Vista SP0** GitHub Actions workflow. It produces
separate x86 and x64 embeddable ZIP artifacts.

For a local build, install Visual Studio 2022, the Windows 10/11 SDK, the
Universal CRT SDK, and the MSVC v140 toolset. Then run:

```bat
git apply v3.12\vista-sp0\patches\0001-pre-kb2533623-dll-loading.patch
set PATCHDIR=C:\src\cpython-windows-vista-and-7\v3.12\Python-3.12.10\api-ms-win-core-path-HACK
v3.12\Python-3.12.10\PCbuild\build.bat -p x64 -c Release "/p:PlatformToolset=v140"
```

Package and audit it from PowerShell:

```powershell
./v3.12/vista-sp0/New-EmbedPackage.ps1 -Platform x64 -OutputDirectory ./artifacts
./v3.12/vista-sp0/Test-PeImports.ps1 -PackageDirectory ./artifacts/python-3.12.10-vista-sp0-x64
```

## Required RTM validation

Test both architectures that will be deployed, using snapshots with no service
packs and no post-RTM Windows updates:

1. Start `python.exe` and run `vista-sp0/smoke_test.py`.
2. Import the complete agent dependency set, including RPyC.
3. Load the VMCI extension and bind, listen, accept, send, and receive over a
   VMCI socket.
4. Restart the agent repeatedly and verify that handles and VMCI ports are
   released.
5. Repeat on Windows 7 RTM because it exercises the same pre-KB loader path.

The VMCI extension is intentionally a separate deliverable. It should use the
same v140 toolset and should not require changes to CPython's `_socket` module.
