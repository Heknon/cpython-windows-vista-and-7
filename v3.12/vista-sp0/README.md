# Python 3.12.10 for Vista and Windows 7 RTM

This directory contains the build and validation tooling for an embeddable
Python 3.12.10 distribution intended to run on Windows Vista RTM (SP0) and
Windows 7 RTM without KB2533623.

This is an experimental compatibility target. A successful hosted build is
not proof of RTM compatibility. PR #1 must not merge until the packaged guest
validator passes on clean RTM virtual machines for every published
architecture.

## Compatibility changes

- `patches/0001-pre-kb2533623-dll-loading.patch` is applied before the
  build, leaving the imported Vista fork easy to refresh from upstream.
- `Py_WINVER`, `WINVER`, and `_WIN32_WINNT` are set to `0x0600`, and
  `NTDDI_VERSION` is set to `NTDDI_VISTA` throughout the CPython build.
- The build uses the `v141_xp` platform toolset and Windows 7.1A SDK instead
  of compiling against the Windows 10 SDK contract.
- `AddDllDirectory` and `RemoveDllDirectory` are resolved with
  `GetProcAddress`, preventing the Windows loader from rejecting
  `python312.dll` when those KB2533623 exports are absent.
- The extension-module loader first uses CPython's restricted modern search
  flags. If and only if Windows returns `ERROR_INVALID_PARAMETER`, it retries
  the absolute module path with `LOAD_WITH_ALTERED_SEARCH_PATH`.
- The app-local UCRT and VC141 runtime payloads are selected by exact SHA-256
  digests in `RuntimeHashes.psd1`; runner directory ordering cannot silently
  change the shipped runtime.
- The PE audit checks the dependency closure, executable subsystem version,
  and known post-Vista imports. A DLL that is neither packaged nor in the
  Vista RTM system-DLL allowlist fails the build.
- The source-loader audit rejects new, unreviewed `LoadLibraryEx` call sites
  and verifies the pre-KB2533623 fallbacks used by both the extension loader
  and `_ctypes`.
- Before importing packaged extension modules, the RTM guest preflight parses
  every packaged PE image and verifies each normal and delay-loaded import
  against the exports of the actual clean guest's system DLLs. Forwarded
  exports are resolved recursively.
- The packaged smoke test imports every `.pyd` in the artifact and exercises
  files, `shutil.copy`, `copy2`, `copytree`, compression, hashing, XML,
  SQLite, SSL initialization, both default `ctypes` DLL-loading modes, memory
  mapping, clocks, threads, subprocesses, TCP loopback, and `asyncio`.

The hosted system-DLL list remains a DLL-name allowlist rather than an RTM
export manifest. Exact symbol compatibility is therefore decided by the
packaged on-guest PE preflight against the genuine RTM system DLLs, not inferred
from a successful build on a modern host.

## Current status and remaining blocker

The hosted build, complete PE dependency/forwarder audit, packaging, and smoke
tests pass for x86 and x64. The package pins the complete Windows SDK
10.0.10240 app-local UCRT payload and desktop VC141 runtime by SHA-256.

This is still not proof that the Windows Vista RTM loader and kernel exports
accept every binary. Clean Vista RTM and Windows 7 RTM guest validation below
remains the merge blocker. Do not substitute a newer host smoke test or a VM
with service packs, updates, redistributables, or VMware Tools installed.

## Build

Run the **Build Python 3.12 for Vista SP0** GitHub Actions workflow. It builds
separate x86 and x64 packages. A ZIP is created only after the runtime hashes
and PE dependency closure pass.

For a local build, install Visual Studio 2022, Windows XP support for the VS2017
C++ tools, and the Windows 7.1A SDK. Then run:

```bat
git apply v3.12\vista-sp0\patches\0001-pre-kb2533623-dll-loading.patch
set PATCHDIR=C:\src\cpython-windows-vista-and-7\v3.12\Python-3.12.10\api-ms-win-core-path-HACK
v3.12\Python-3.12.10\PCbuild\build.bat -p x64 -c Release "/p:PlatformToolset=v141_xp" "/p:VCToolsVersion=14.16.27023" "/p:WindowsTargetPlatformVersion=7.0"
```

Package and audit it from PowerShell:

```powershell
./v3.12/vista-sp0/New-EmbedPackage.ps1 -Platform x64 -OutputDirectory ./artifacts
```

## Required RTM guest validation

Take snapshots before installing service packs, Windows updates, Visual C++
redistributables, Python, or VMware Tools. Copy only the produced ZIP into the
guest, extract it, and run:

```bat
guest_validate.cmd
```

Preserve `guest-validation.log`, `ARTIFACT-MANIFEST.json`, the ZIP SHA-256,
the VM configuration, and a screenshot of `winver`. The validator refuses to
pass unless `sys.getwindowsversion()` reports exactly Vista RTM `6.0.6000` or
Windows 7 RTM `6.1.7600`.

Minimum evidence before merging PR #1:

| Guest | x86 package | x64 package |
|---|---:|---:|
| Vista RTM 6.0.6000 | required | required |
| Windows 7 RTM 6.1.7600 | required | required |

An x86 package should be tested on a 32-bit guest, not only under WOW64. The
x64 package needs a 64-bit guest. Repeat each test from a reverted clean
snapshot so a previous runtime installation cannot mask a missing DLL.

VMCI socket behavior and VMware Tools installation belong to the VMCI PR, not
this CPython-runtime PR. PR #1 only needs a hypervisor-neutral clean-guest
Python result. Do not install VMware Tools merely to copy the artifact; use an
ISO or another method that does not modify the guest runtime.

## Why `exit()` is undefined

The embeddable package's `python312._pth` intentionally comments out
`import site`. The convenience names `exit` and `quit` are installed by
`site`, so they are undefined in this package. Use `sys.exit()` in programs or
press Ctrl+Z followed by Enter at the interactive prompt. Uncomment
`import site` only if normal site initialization is actually desired.
