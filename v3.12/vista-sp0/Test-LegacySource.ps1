[CmdletBinding()]
param(
    [string]$SourceRoot = (Join-Path $PSScriptRoot "..\Python-3.12.10")
)

$ErrorActionPreference = "Stop"
$failures = New-Object System.Collections.Generic.List[string]

function Require-Pattern {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Description
    )
    $content = Get-Content $Path -Raw
    if ($content -notmatch $Pattern) {
        $failures.Add("$Description is missing from $Path")
    }
}

$ctypes = Join-Path $SourceRoot "Modules\_ctypes\callproc.c"
$dynload = Join-Path $SourceRoot "Python\dynload_win.c"
$fileutils = Join-Path $SourceRoot "Python\fileutils.c"
$posix = Join-Path $SourceRoot "Modules\posixmodule.c"
$osModule = Join-Path $SourceRoot "Lib\os.py"

Require-Pattern $ctypes `
    '(?m)^#define LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR 0x00000100\r?$' `
    "the Windows 7.1A SDK DLL-load-directory flag definition"
Require-Pattern $ctypes `
    '(?m)^#define LOAD_LIBRARY_SEARCH_DEFAULT_DIRS 0x00001000\r?$' `
    "the Windows 7.1A SDK default-directory flag definition"
Require-Pattern $ctypes `
    'GetProcAddress\(kernel32,\s*"AddDllDirectory"\)' `
    "the pre-KB2533623 _ctypes capability check"
Require-Pattern $ctypes `
    'LOAD_LIBRARY_SEARCH_DEFAULT_DIRS\s*\|\s*LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR[\s\S]+LOAD_WITH_ALTERED_SEARCH_PATH' `
    "the _ctypes absolute-path legacy retry"
Require-Pattern $ctypes `
    'LOAD_LIBRARY_SEARCH_DEFAULT_DIRS[\s\S]+retry_with_legacy_flags' `
    "the _ctypes bare-name legacy retry"
Require-Pattern $dynload `
    'load_library_ex_compat[\s\S]+ERROR_INVALID_PARAMETER[\s\S]+legacy_flags' `
    "the extension-loader legacy retry"
Require-Pattern $fileutils `
    'PY_VISTA_LEGACY_SDK[\s\S]+LoadLibraryW\(L"api-ms-win-core-path-l1-1-0\.dll"\)' `
    "the PathCch legacy loader"
Require-Pattern $posix `
    'GetProcAddress\([\s\S]+"AddDllDirectory"\)' `
    "dynamic AddDllDirectory resolution"
Require-Pattern $posix `
    'GetProcAddress\([\s\S]+"RemoveDllDirectory"\)' `
    "dynamic RemoveDllDirectory resolution"
Require-Pattern $osModule `
    'except NotImplementedError:[\s\S]+_legacy_add_dll_directory' `
    "the pre-KB2533623 os.add_dll_directory fallback"
Require-Pattern $osModule `
    '_legacy_dll_directories[\s\S]+environ\[''PATH''\]' `
    "the legacy multi-directory DLL search path"

$directForbidden = @(
    @{ Pattern = '(?m)\bAddDllDirectory\s*\('; Name = "AddDllDirectory" },
    @{ Pattern = '(?m)\bRemoveDllDirectory\s*\('; Name = "RemoveDllDirectory" },
    @{ Pattern = '(?m)\bSetDefaultDllDirectories\s*\('; Name = "SetDefaultDllDirectories" }
)
foreach ($entry in $directForbidden) {
    Get-ChildItem $SourceRoot -File -Recurse -Include *.c,*.cpp | ForEach-Object {
        $content = Get-Content $_.FullName -Raw
        if ($content -cmatch $entry.Pattern) {
            $failures.Add("$($_.FullName) directly calls $($entry.Name)")
        }
    }
}

$approvedLoadLibraryExFiles = @(
    (Join-Path $SourceRoot "Modules\_ctypes\callproc.c"),
    (Join-Path $SourceRoot "Python\dynload_win.c"),
    (Join-Path $SourceRoot "Python\fileutils.c")
) | ForEach-Object { [IO.Path]::GetFullPath($_).ToUpperInvariant() }

Get-ChildItem $SourceRoot -File -Recurse -Include *.c,*.cpp | ForEach-Object {
    if (Select-String -Path $_.FullName -Pattern 'LoadLibraryEx(?:A|W)?\s*\(' -Quiet) {
        $normalized = [IO.Path]::GetFullPath($_.FullName).ToUpperInvariant()
        if ($normalized -notin $approvedLoadLibraryExFiles) {
            $failures.Add("unreviewed LoadLibraryEx call site in $($_.FullName)")
        }
    }
}

# GetProcAddress hides API dependencies from the PE import table. Keep every
# source file that uses it under explicit review so a new dynamic post-Vista
# API cannot bypass the static import audit unnoticed.
$approvedGetProcAddressFiles = @(
    (Join-Path $SourceRoot "Include\internal\pycore_fileutils_windows.h"),
    (Join-Path $SourceRoot "Modules\_ctypes\_ctypes.c"),
    (Join-Path $SourceRoot "Modules\_ctypes\callproc.c"),
    (Join-Path $SourceRoot "Modules\_ssl.c"),
    (Join-Path $SourceRoot "Modules\_winapi.c"),
    (Join-Path $SourceRoot "Modules\posixmodule.c"),
    (Join-Path $SourceRoot "PC\frozen_dllmain.c"),
    (Join-Path $SourceRoot "PC\launcher2.c"),
    (Join-Path $SourceRoot "PC\winreg.c"),
    (Join-Path $SourceRoot "Python\dynload_win.c"),
    (Join-Path $SourceRoot "Python\fileutils.c"),
    (Join-Path $SourceRoot "Tools\msi\bundle\bootstrap\PythonBootstrapperApplication.cpp")
) | ForEach-Object { [IO.Path]::GetFullPath($_).ToUpperInvariant() }

Get-ChildItem $SourceRoot -File -Recurse -Include *.c,*.cpp,*.h | ForEach-Object {
    if (Select-String -Path $_.FullName -Pattern '\bGetProcAddress\s*\(' -Quiet) {
        $normalized = [IO.Path]::GetFullPath($_.FullName).ToUpperInvariant()
        if ($normalized -notin $approvedGetProcAddressFiles) {
            $failures.Add("unreviewed GetProcAddress call site in $($_.FullName)")
        }
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    throw "The patched source contains unreviewed pre-KB2533623 loader paths."
}

Write-Host "Legacy source-loader audit passed."
