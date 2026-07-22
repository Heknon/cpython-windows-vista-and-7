[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("x64", "Win32")]
    [string]$Platform,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$sourceRoot = Join-Path $repoRoot "v3.12\Python-3.12.10"
$buildArch = if ($Platform -eq "x64") { "amd64" } else { "win32" }
$sdkArch = if ($Platform -eq "x64") { "x64" } else { "x86" }
$buildDirectory = Join-Path $sourceRoot "PCbuild\$buildArch"
$packageDirectory = Join-Path $OutputDirectory "python-3.12.10-vista-sp0-$sdkArch"
$runtimeDirectory = "$packageDirectory-runtime"
$runtimeZip = "$runtimeDirectory.zip"
$validationZip = "$packageDirectory-validation.zip"
$tempDirectory = Join-Path $env:RUNNER_TEMP "python-layout-$sdkArch"
$runtimeHashes = Import-PowerShellDataFile (Join-Path $PSScriptRoot "RuntimeHashes.psd1")
$expectedHashes = $runtimeHashes[$sdkArch]

function Test-ExpectedHash {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedHash
    )

    if (!(Test-Path $Path -PathType Leaf)) {
        return $false
    }
    $actualHash = (Get-FileHash $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    return $actualHash -eq $ExpectedHash
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
if (Test-Path $packageDirectory) {
    Remove-Item -Recurse -Force $packageDirectory
}
if (Test-Path $runtimeDirectory) {
    Remove-Item -Recurse -Force $runtimeDirectory
}
if (Test-Path $tempDirectory) {
    Remove-Item -Recurse -Force $tempDirectory
}

$layoutArguments = @(
    (Join-Path $sourceRoot "PC\layout\main.py")
    "--source", $sourceRoot
    "--build", $buildDirectory
    "--arch", $buildArch
    "--copy", $packageDirectory
    "--temp", $tempDirectory
    "--preset-embed"
)
& (Join-Path $buildDirectory "python.exe") @layoutArguments
if ($LASTEXITCODE -ne 0) {
    throw "Creating the embeddable layout failed with exit code $LASTEXITCODE."
}

# Vista RTM cannot rely on the system Universal CRT update. Select one exact,
# reviewed UCRT payload by content rather than accepting whichever SDK happens
# to sort first on the runner.
$ucrtDirectories = Get-ChildItem (Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\Redist") `
    -Directory -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "\\ucrt\\DLLs\\$sdkArch$" } |
    Sort-Object FullName

$vcRuntimeFiles = @("vcruntime140.dll", "msvcp140.dll", "concrt140.dll")
$ucrtFiles = $expectedHashes.Keys | Where-Object { $_ -notin $vcRuntimeFiles }
$ucrtDirectory = $ucrtDirectories | Where-Object {
    $candidate = $_.FullName
    @($ucrtFiles | Where-Object {
        !(Test-ExpectedHash (Join-Path $candidate $_) $expectedHashes[$_])
    }).Count -eq 0
} | Select-Object -First 1
if (!$ucrtDirectory) {
    throw "Could not locate the reviewed app-local UCRT payload for $sdkArch."
}
foreach ($fileName in $ucrtFiles) {
    Copy-Item (Join-Path $ucrtDirectory.FullName $fileName) $packageDirectory -Force
}
Write-Host "Selected reviewed UCRT payload from $($ucrtDirectory.FullName)."

# The current VC runtime has a Windows 7 floor. Locate the runtime installed
# with the v141 toolset and replace the copy selected by the normal build.
$visualStudioRoot = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio"
$v141RedistRoot = if ($env:V141_REDIST_ROOT) { $env:V141_REDIST_ROOT } else { $visualStudioRoot }
$v141Runtimes = Get-ChildItem $v141RedistRoot -Filter "vcruntime140.dll" -File -Recurse |
    Where-Object {
        $_.FullName -match "Microsoft\.VC141\.CRT" -and
        $_.FullName -match "\\$sdkArch\\" -and
        $_.FullName -notmatch "\\onecore\\"
    } |
    Sort-Object FullName
$v141Runtime = $v141Runtimes | Where-Object {
    Test-ExpectedHash $_.FullName $expectedHashes["vcruntime140.dll"]
} | Select-Object -First 1

if (!$v141Runtime) {
    Write-Host "VC141 runtime candidates for ${sdkArch}:"
    $v141Runtimes | ForEach-Object {
        $hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        Write-Host "  $($_.VersionInfo.FileVersion) $hash $($_.FullName)"
    }
}
if (!$v141Runtime -or !(Test-ExpectedHash $v141Runtime.FullName $expectedHashes["vcruntime140.dll"])) {
    throw "Could not locate the reviewed $sdkArch Microsoft.VC141.CRT runtime. Pin a reviewed XP-compatible candidate; do not downgrade it to VC140."
}
$v141VersionMatch = [regex]::Match($v141Runtime.VersionInfo.FileVersion, "^\d+\.\d+\.\d+\.\d+")
if (!$v141VersionMatch.Success) {
    throw "Could not parse the VC141 runtime version at $($v141Runtime.FullName)."
}
$v141Version = [Version]$v141VersionMatch.Value
if ($v141Version.Major -ne 14 -or $v141Version.Minor -lt 10 -or $v141Version.Minor -ge 20) {
    throw "Expected a 14.1x VC141 runtime, found $v141Version at $($v141Runtime.FullName)."
}
Copy-Item $v141Runtime.FullName $packageDirectory -Force

# Native third-party packages may use the VC++ standard library even though
# CPython itself does not. Keep that runtime app-local as well; it is not a
# Vista system DLL. Select it by digest from the same desktop VC141 payload as
# vcruntime140.dll.
$v141CppRuntimes = Get-ChildItem $v141RedistRoot -Filter "msvcp140.dll" -File -Recurse |
    Where-Object {
        $_.FullName -match "Microsoft\.VC141\.CRT" -and
        $_.FullName -match "\\$sdkArch\\" -and
        $_.FullName -notmatch "\\onecore\\"
    } |
    Sort-Object FullName
$v141CppRuntime = $v141CppRuntimes | Where-Object {
    Test-ExpectedHash $_.FullName $expectedHashes["msvcp140.dll"]
} | Select-Object -First 1
if (!$v141CppRuntime) {
    throw "Could not locate the reviewed $sdkArch Microsoft.VC141.CRT C++ runtime."
}
$v141CppVersionMatch = [regex]::Match(
    $v141CppRuntime.VersionInfo.FileVersion, "^\d+\.\d+\.\d+\.\d+"
)
if (!$v141CppVersionMatch.Success) {
    throw "Could not parse the VC141 C++ runtime version at $($v141CppRuntime.FullName)."
}
$v141CppVersion = [Version]$v141CppVersionMatch.Value
if ($v141CppVersion.Major -ne 14 -or
        $v141CppVersion.Minor -lt 10 -or
        $v141CppVersion.Minor -ge 20) {
    throw "Expected a 14.1x VC141 C++ runtime, found $v141CppVersion at $($v141CppRuntime.FullName)."
}
Write-Host "Selected reviewed msvcp140.dll $v141CppVersion from $($v141CppRuntime.FullName)."
Copy-Item $v141CppRuntime.FullName $packageDirectory -Force

# msvcp140.dll uses the Concurrency Runtime from the same VC141 desktop
# payload. Keep the reviewed, hash-pinned pair together.
$v141ConcurrencyRuntime = Join-Path $v141CppRuntime.Directory.FullName "concrt140.dll"
if (!(Test-ExpectedHash `
        $v141ConcurrencyRuntime $expectedHashes["concrt140.dll"])) {
    throw "The selected Microsoft.VC141.CRT payload has no reviewed concrt140.dll."
}
$v141ConcurrencyVersionMatch = [regex]::Match(
    (Get-Item $v141ConcurrencyRuntime).VersionInfo.FileVersion,
    "^\d+\.\d+\.\d+\.\d+"
)
if (!$v141ConcurrencyVersionMatch.Success) {
    throw "Could not parse the VC141 Concurrency Runtime version at $v141ConcurrencyRuntime."
}
$v141ConcurrencyVersion = [Version]$v141ConcurrencyVersionMatch.Value
if ($v141ConcurrencyVersion.Major -ne 14 -or
        $v141ConcurrencyVersion.Minor -lt 10 -or
        $v141ConcurrencyVersion.Minor -ge 20) {
    throw "Expected a 14.1x VC141 Concurrency Runtime, found $v141ConcurrencyVersion at $v141ConcurrencyRuntime."
}
Write-Host "Selected reviewed concrt140.dll $v141ConcurrencyVersion from $v141ConcurrencyRuntime."
Copy-Item $v141ConcurrencyRuntime $packageDirectory -Force

# vcruntime140_1.dll was introduced after VC141. The embeddable-layout helper
# may copy the runner's current runtime, so remove that unrelated DLL. The PE
# dependency audit below will fail if any packaged binary actually requires it.
$newerRuntime = Join-Path $packageDirectory "vcruntime140_1.dll"
if (Test-Path $newerRuntime) {
    Remove-Item -Force $newerRuntime
}

foreach ($fileName in $expectedHashes.Keys) {
    $path = Join-Path $packageDirectory $fileName
    if (!(Test-ExpectedHash $path $expectedHashes[$fileName])) {
        throw "$fileName does not match its reviewed SHA-256 digest."
    }
}

# Put the tests beside python.exe so the same bits tested by Actions can be
# copied directly into a clean RTM guest without checking out the repository.
Copy-Item (Join-Path $PSScriptRoot "smoke_test.py") $packageDirectory -Force
Copy-Item (Join-Path $PSScriptRoot "guest_validate.py") $packageDirectory -Force
Copy-Item (Join-Path $PSScriptRoot "guest_validate.cmd") $packageDirectory -Force
Copy-Item (Join-Path $PSScriptRoot "rtm_preflight.py") $packageDirectory -Force
Copy-Item (Join-Path $PSScriptRoot "rtm_regression.py") $packageDirectory -Force
Copy-Item (Join-Path $PSScriptRoot "third_party_smoke.py") $packageDirectory -Force

# A separate executable and versioned path file expose an unpacked source
# library to regression subprocesses without changing the normal shipping
# interpreter's optimized python312.zip behavior.  Keep the library in the
# conventional location beside this executable so sys._stdlib_dir and frozen
# module source metadata describe the same tree that the tests import.
$validationRunner = Join-Path $packageDirectory "validation-runner"
New-Item -ItemType Directory -Force -Path $validationRunner | Out-Null
Copy-Item (Join-Path $packageDirectory "python.exe") $validationRunner -Force
Get-ChildItem $packageDirectory -Filter "*.dll" -File | `
    Copy-Item -Destination $validationRunner -Force
$validationLib = Join-Path $validationRunner "Lib"
New-Item -ItemType Directory -Force -Path $validationLib | Out-Null
Copy-Item (Join-Path $sourceRoot "Lib\*") $validationLib -Recurse -Force

# The embeddable preset deliberately omits CPython's test-only native modules.
# Keep them with the unpacked validation library.
$requiredTestExtensions = @(
    "_ctypes_test.pyd"
    "_testcapi.pyd"
    "_testinternalcapi.pyd"
    "_testmultiphase.pyd"
)
$testExtensions = Get-ChildItem $buildDirectory -File | Where-Object {
    $_.Name -like "_test*.pyd" -or
    $_.Name -eq "_ctypes_test.pyd" -or
    $_.Name -like "xxlimited*.pyd" -or
    $_.Name -eq "xxsubtype.pyd"
}
foreach ($required in $requiredTestExtensions) {
    if ($required -notin $testExtensions.Name) {
        throw "Required CPython regression extension is missing: $required"
    }
}
$testExtensions | Copy-Item -Destination $validationLib -Force

@(
    "Lib"
    "..\python312.zip"
    ".."
) | Set-Content (Join-Path $validationRunner "python312._pth") -Encoding Ascii

# Add a small, reviewed package matrix outside the normal import path.  The PE
# and guest audits below still inspect every native binary recursively, while
# the functional smoke test opts into this directory explicitly.
& (Join-Path $PSScriptRoot "Install-ValidationPackages.ps1") `
    -Platform $Platform `
    -PackageDirectory $packageDirectory
if ($LASTEXITCODE -ne 0) {
    throw "Installing third-party validation packages failed with exit code $LASTEXITCODE."
}

# Add VMCI support before auditing and manifest generation so the extension is
# covered by the same dependency-closure and artifact-integrity checks.
$vmciDirectory = Join-Path $PSScriptRoot "vmci"
Copy-Item (Join-Path $buildDirectory "_vmci.pyd") $packageDirectory -Force
Copy-Item (Join-Path $vmciDirectory "vmci.py") $packageDirectory -Force
Copy-Item (Join-Path $PSScriptRoot "vmci_smoke_test.py") $packageDirectory -Force

& (Join-Path $PSScriptRoot "Test-PeImports.ps1") -PackageDirectory $packageDirectory
if ($LASTEXITCODE -ne 0) {
    throw "PE dependency-closure audit failed with exit code $LASTEXITCODE."
}

$manifestFiles = Get-ChildItem $packageDirectory -File -Recurse | Sort-Object FullName
$manifest = [ordered]@{
    python = "3.12.10"
    architecture = $sdkArch
    files = @($manifestFiles | ForEach-Object {
        [ordered]@{
            path = $_.FullName.Substring($packageDirectory.Length + 1).Replace("\\", "/")
            sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content `
    (Join-Path $packageDirectory "ARTIFACT-MANIFEST.json") -Encoding UTF8

# Keep the deployable archive lean.  The working package above intentionally
# contains the complete guest validator, regression interpreter, and package
# probes.  Copy it, strip only validation-owned payloads, and run the PE audit
# again so removing a DLL that a shipping binary needs cannot produce a broken
# runtime silently.
Copy-Item $packageDirectory $runtimeDirectory -Recurse -Force

$validationOnlyPaths = @(
    "validation-packages"
    "validation-runner"
    "ARTIFACT-MANIFEST.json"
    "THIRD-PARTY-REQUIREMENTS.txt"
    "THIRD-PARTY-REQUIREMENTS-WIN32.txt"
    "guest_validate.cmd"
    "guest_validate.py"
    "rtm_preflight.py"
    "rtm_regression.py"
    "smoke_test.py"
    "third_party_smoke.py"
    "msvcp140.dll"
    "concrt140.dll"
)
foreach ($relativePath in $validationOnlyPaths) {
    $path = Join-Path $runtimeDirectory $relativePath
    if (Test-Path $path) {
        Remove-Item $path -Recurse -Force
    }
}

# Later stacked PRs add their own transport smoke tests.  Their runtime modules
# remain, while files whose names identify them as tests do not ship.
Get-ChildItem $runtimeDirectory -File -Filter "*_smoke_test.py" |
    Remove-Item -Force

$forbiddenRuntimePaths = @(
    "validation-packages"
    "validation-runner"
    "guest_validate.cmd"
    "rtm_regression.py"
    "smoke_test.py"
    "third_party_smoke.py"
)
foreach ($relativePath in $forbiddenRuntimePaths) {
    if (Test-Path (Join-Path $runtimeDirectory $relativePath)) {
        throw "Validation payload leaked into the runtime archive: $relativePath"
    }
}

& (Join-Path $PSScriptRoot "Test-PeImports.ps1") -PackageDirectory $runtimeDirectory
if ($LASTEXITCODE -ne 0) {
    throw "Lean runtime PE dependency-closure audit failed with exit code $LASTEXITCODE."
}
Remove-Item (Join-Path $runtimeDirectory "PE-IMPORTS.json") -Force

foreach ($archive in @($runtimeZip, $validationZip)) {
    if (Test-Path $archive) {
        Remove-Item -Force $archive
    }
}
Compress-Archive -Path (Join-Path $runtimeDirectory "*") -DestinationPath $runtimeZip
Compress-Archive -Path (Join-Path $packageDirectory "*") -DestinationPath $validationZip

$runtimeSize = [Math]::Round((Get-Item $runtimeZip).Length / 1MB, 2)
$validationSize = [Math]::Round((Get-Item $validationZip).Length / 1MB, 2)
Write-Host "Created lean runtime: $runtimeZip ($runtimeSize MB)"
Write-Host "Created validation bundle: $validationZip ($validationSize MB)"
