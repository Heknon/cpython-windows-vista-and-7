[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageDirectory,

    [string]$AllowedSystemDllsPath = (Join-Path $PSScriptRoot "VistaRtmSystemDlls.psd1")
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

$allowedSystemDlls = @(
    Import-PowerShellDataFile $AllowedSystemDllsPath |
        ForEach-Object { $_.ToUpperInvariant() }
)
$packagedDlls = @{}
Get-ChildItem $PackageDirectory -File -Recurse | ForEach-Object {
    $packagedDlls[$_.Name.ToUpperInvariant()] = $true
}

$failures = New-Object System.Collections.Generic.List[string]
$dependencyReport = New-Object System.Collections.Generic.List[object]
$binaries = Get-ChildItem $PackageDirectory -File -Recurse |
    Where-Object { $_.Extension -in @(".dll", ".exe", ".pyd") }

foreach ($binary in $binaries) {
    $imports = & $dumpbin.FullName /nologo /imports $binary.FullName 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        $failures.Add("dumpbin could not inspect $($binary.Name)")
        continue
    }

    $dependencies = @(
        [regex]::Matches($imports, "(?m)^\s+([A-Za-z0-9_.-]+\.dll)\s*$") |
            ForEach-Object { $_.Groups[1].Value.ToUpperInvariant() } |
            Sort-Object -Unique
    )
    $dependencyReport.Add([ordered]@{
        binary = $binary.FullName.Substring($PackageDirectory.Length + 1).Replace("\\", "/")
        imports = $dependencies
    })

    foreach ($dependency in $dependencies) {
        if (!$packagedDlls.ContainsKey($dependency) -and $dependency -notin $allowedSystemDlls) {
            $failures.Add(
                "$($binary.Name) imports $dependency, which is neither packaged nor allowed on Vista RTM"
            )
        }
    }

    foreach ($symbol in $forbiddenImports) {
        if ($imports -match "(?m)^\s+$([regex]::Escape($symbol))\s*$") {
            $failures.Add("$($binary.Name) statically imports $symbol")
        }
    }

    $headers = & $dumpbin.FullName /nologo /headers $binary.FullName 2>&1 | Out-String
    $subsystem = [regex]::Match($headers, "(?m)^\s+([0-9]+\.[0-9]+) subsystem version\s*$")
    if (!$subsystem.Success) {
        $failures.Add("could not read the PE subsystem version for $($binary.Name)")
    } elseif ([Version]$subsystem.Groups[1].Value -gt [Version]"6.0") {
        $failures.Add("$($binary.Name) requires subsystem version $($subsystem.Groups[1].Value)")
    }
}

$reportPath = Join-Path $PackageDirectory "PE-IMPORTS.json"
$dependencyReport | ConvertTo-Json -Depth 4 | Set-Content $reportPath -Encoding UTF8

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    throw "The package contains APIs that are unavailable on Vista RTM."
}

Write-Host "PE dependency-closure audit passed for $($binaries.Count) binaries."