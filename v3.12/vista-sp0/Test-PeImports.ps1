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
    (Import-PowerShellDataFile $AllowedSystemDllsPath).Dlls |
        ForEach-Object { $_.ToUpperInvariant() }
)
$failures = New-Object System.Collections.Generic.List[string]

function Get-NormalizedDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd('\').ToUpperInvariant()
}

$packageDirectory = [IO.Path]::GetFullPath($PackageDirectory)
$searchableDirectories = New-Object 'System.Collections.Generic.HashSet[string]' `
    ([StringComparer]::OrdinalIgnoreCase)
[void]$searchableDirectories.Add((Get-NormalizedDirectory $packageDirectory))
if ($env:PATH) {
    $env:PATH.Split([IO.Path]::PathSeparator) | Where-Object { $_ } | ForEach-Object {
        [void]$searchableDirectories.Add((Get-NormalizedDirectory $_))
    }
}
Get-ChildItem $PackageDirectory -Directory -Recurse | Where-Object {
    $_.Name -ieq 'pywin32_system32' -or $_.Name.EndsWith('.libs', [StringComparison]::OrdinalIgnoreCase)
} | ForEach-Object {
    [void]$searchableDirectories.Add((Get-NormalizedDirectory $_.FullName))
}

$dllDirectoryDeclaration = Join-Path $PackageDirectory 'RTM-DLL-DIRECTORIES.txt'
if (Test-Path $dllDirectoryDeclaration -PathType Leaf) {
    $lineNumber = 0
    Get-Content $dllDirectoryDeclaration | ForEach-Object {
        $lineNumber++
        $relative = $_.Trim()
        if ($relative -and !$relative.StartsWith('#')) {
            $candidate = [IO.Path]::GetFullPath((Join-Path $PackageDirectory $relative))
            $insidePackage = $candidate -ieq $PackageDirectory -or
                $candidate.StartsWith($PackageDirectory.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
            if (!$insidePackage) {
                $failures.Add("RTM-DLL-DIRECTORIES.txt:${lineNumber}: directory escapes package root")
            } elseif (!(Test-Path $candidate -PathType Container)) {
                $failures.Add("RTM-DLL-DIRECTORIES.txt:${lineNumber}: directory does not exist: $relative")
            } else {
                [void]$searchableDirectories.Add((Get-NormalizedDirectory $candidate))
            }
        }
    }
}

$packagedDlls = @{}
Get-ChildItem $PackageDirectory -File -Recurse | ForEach-Object {
    $key = $_.Name.ToUpperInvariant()
    if (!$packagedDlls.ContainsKey($key)) {
        $packagedDlls[$key] = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    }
    $packagedDlls[$key].Add($_)
}

$missingDependencies = New-Object System.Collections.Generic.HashSet[string]
$dependencyReport = New-Object System.Collections.Generic.List[object]
$binaries = Get-ChildItem $PackageDirectory -File -Recurse |
    Where-Object { $_.Extension -in @(".dll", ".exe", ".pyd") }

foreach ($entry in $packagedDlls.GetEnumerator()) {
    if ($entry.Value.Count -lt 2 -or
        [IO.Path]::GetExtension($entry.Key).ToLowerInvariant() -notin @(".dll", ".exe", ".pyd")) {
        continue
    }
    $hashes = @($entry.Value | ForEach-Object {
        (Get-FileHash $_.FullName -Algorithm SHA256).Hash
    } | Sort-Object -Unique)
    if ($hashes.Count -gt 1) {
        $locations = @($entry.Value | ForEach-Object {
            $_.FullName.Substring($PackageDirectory.Length + 1).Replace("\", "/")
        }) -join ", "
        $failures.Add("$($entry.Key) has conflicting duplicate binaries: $locations")
    }
}

$pythonDll = Get-ChildItem $PackageDirectory -Filter "python3*.dll" -File |
    Where-Object { $_.Name -ne "python3.dll" } |
    Select-Object -First 1
if (!$pythonDll) {
    $failures.Add("the versioned Python runtime DLL is missing")
} else {
    $pythonHeaders = & $dumpbin.FullName /nologo /headers $pythonDll.FullName 2>&1 | Out-String
    $linker = [regex]::Match($pythonHeaders, "(?m)^\s+([0-9]+\.[0-9]+) linker version\s*$")
    if (!$linker.Success) {
        $failures.Add("could not read the linker version for $($pythonDll.Name)")
    } elseif ([Version]$linker.Groups[1].Value -lt [Version]"14.10" -or
              [Version]$linker.Groups[1].Value -ge [Version]"14.20") {
        $failures.Add(
            "$($pythonDll.Name) was linked by $($linker.Groups[1].Value), not the required VC141 14.1x toolset"
        )
    }
}

foreach ($binary in $binaries) {
    $imports = & $dumpbin.FullName /nologo /imports $binary.FullName 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        $failures.Add("dumpbin could not inspect $($binary.Name)")
        continue
    }

    $importedDependencies = @(
        [regex]::Matches($imports, "(?m)^\s+([A-Za-z0-9_.-]+\.dll)\s*$") |
            ForEach-Object { $_.Groups[1].Value.ToUpperInvariant() } |
            Sort-Object -Unique
    )

    $exports = & $dumpbin.FullName /nologo /exports $binary.FullName 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        $failures.Add("dumpbin could not inspect exports from $($binary.Name)")
        continue
    }
    $forwarderDependencies = @(
        [regex]::Matches($exports, "(?m)=\s+([A-Za-z0-9_-]+)\.[^\s]+") |
            ForEach-Object { ($_.Groups[1].Value + ".DLL").ToUpperInvariant() } |
            Sort-Object -Unique
    )
    $dependencies = @($importedDependencies + $forwarderDependencies | Sort-Object -Unique)
    $dependencyReport.Add([ordered]@{
        binary = $binary.FullName.Substring($PackageDirectory.Length + 1).Replace("\\", "/")
        imports = $importedDependencies
        forwarders = $forwarderDependencies
    })

    foreach ($dependency in $dependencies) {
        if (!$packagedDlls.ContainsKey($dependency) -and $dependency -notin $allowedSystemDlls) {
            [void]$missingDependencies.Add($dependency)
            $failures.Add(
                "$($binary.Name) depends on $dependency, which is neither packaged nor allowed on Vista RTM"
            )
        } elseif ($packagedDlls.ContainsKey($dependency) -and $dependency -notin $allowedSystemDlls) {
            $binaryDirectory = Get-NormalizedDirectory $binary.DirectoryName
            $reachable = @($packagedDlls[$dependency] | Where-Object {
                $candidateDirectory = Get-NormalizedDirectory $_.DirectoryName
                $candidateDirectory -eq $binaryDirectory -or
                    $searchableDirectories.Contains($candidateDirectory)
            })
            if ($reachable.Count -eq 0) {
                $locations = @($packagedDlls[$dependency] | ForEach-Object {
                    $_.FullName.Substring($PackageDirectory.Length + 1).Replace('\', '/')
                }) -join ', '
                $failures.Add(
                    "$($binary.Name) depends on packaged $dependency, but no copy is reachable: $locations"
                )
            }
        }
    }

    foreach ($symbol in $forbiddenImports) {
        if ($imports -match "(?m)^\s+$([regex]::Escape($symbol))\s*$") {
            $failures.Add("$($binary.Name) statically imports $symbol")
        }
    }

    # Windows enforces the subsystem-version floor on process images. Microsoft
    # UCRT forwarder DLLs intentionally carry 10.0 headers while supporting
    # app-local deployment on Vista, so applying the EXE rule to DLLs rejects
    # the documented down-level runtime payload.
    if ($binary.Extension -eq ".exe") {
        $headers = & $dumpbin.FullName /nologo /headers $binary.FullName 2>&1 | Out-String
        $subsystem = [regex]::Match($headers, "(?m)^\s+([0-9]+\.[0-9]+) subsystem version\s*$")
        if (!$subsystem.Success) {
            $failures.Add("could not read the PE subsystem version for $($binary.Name)")
        } elseif ([Version]$subsystem.Groups[1].Value -gt [Version]"6.0") {
            $failures.Add("$($binary.Name) requires subsystem version $($subsystem.Groups[1].Value)")
        }
    }
}

$reportPath = Join-Path $PackageDirectory "PE-IMPORTS.json"
$dependencyReport | ConvertTo-Json -Depth 4 | Set-Content $reportPath -Encoding UTF8

if ($failures.Count -gt 0) {
    if ($missingDependencies.Count -gt 0) {
        $redistRoots = @(
            (Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\Redist")
            (Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio")
        ) | Where-Object { Test-Path $_ }
        $redistFiles = @($redistRoots | ForEach-Object {
            Get-ChildItem $_ -File -Recurse -ErrorAction SilentlyContinue
        })
        foreach ($dependency in ($missingDependencies | Sort-Object)) {
            Write-Host "Redistributable candidates for ${dependency}:"
            $candidates = @($redistFiles | Where-Object { $_.Name -ieq $dependency })
            if ($candidates.Count -eq 0) {
                Write-Host "  none"
                continue
            }
            $candidates | ForEach-Object {
                $hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                Write-Host "  $($_.VersionInfo.FileVersion) $hash $($_.FullName)"
            }
        }
    }
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    throw "The package contains APIs that are unavailable on Vista RTM."
}

Write-Host "PE dependency-closure audit passed for $($binaries.Count) binaries."
