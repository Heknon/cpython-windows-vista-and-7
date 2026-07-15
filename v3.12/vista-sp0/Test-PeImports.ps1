[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageDirectory
)

$ErrorActionPreference = "Stop"

$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
$installPath = & $vswhere -latest -products * -property installationPath
$dumpbin = Get-ChildItem $installPath -Filter "dumpbin.exe" -File -Recurse |
    Where-Object { $_.FullName -match "Hostx64\\x64" } |
    Select-Object -First 1

if (!$dumpbin) {
    throw "dumpbin.exe was not found."
}

$forbiddenImports = @(
    "AddDllDirectory"
    "CopyFile2"
    "GetActiveProcessorCount"
    "GetSystemTimePreciseAsFileTime"
    "PssCaptureSnapshot"
    "PssFreeSnapshot"
    "PssQuerySnapshot"
    "RemoveDllDirectory"
    "SetDefaultDllDirectories"
    "SetWaitableTimerEx"
)

$failures = New-Object System.Collections.Generic.List[string]
$binaries = Get-ChildItem $PackageDirectory -File -Recurse |
    Where-Object { $_.Extension -in @(".dll", ".exe", ".pyd") }

foreach ($binary in $binaries) {
    $imports = & $dumpbin.FullName /nologo /imports $binary.FullName 2>&1 | Out-String
    foreach ($symbol in $forbiddenImports) {
        if ($imports -match "(?m)^\s+$([regex]::Escape($symbol))\s*$") {
            $failures.Add("$($binary.Name) statically imports $symbol")
        }
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    throw "The package contains APIs that are unavailable on Vista RTM."
}

Write-Host "PE import audit passed for $($binaries.Count) binaries."
