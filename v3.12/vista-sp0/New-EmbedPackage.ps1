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
$packageZip = "$packageDirectory.zip"
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

function Get-Vc140RuntimeFromRedist {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Architecture
    )

    $redistRoot = Join-Path $env:RUNNER_TEMP "vc140-redist-$Architecture"
    $redistExe = Join-Path $redistRoot "vc_redist.$Architecture.exe"
    $redistLayout = Join-Path $redistRoot "layout"
    $redistExtract = Join-Path $redistRoot "extract"
    $redistUrl = "https://download.microsoft.com/download/6/A/A/6AA4EDFF-645B-48C5-81CC-ED5963AEAD48/vc_redist.$Architecture.exe"

    if (Test-Path $redistRoot) {
        Remove-Item -Recurse -Force $redistRoot
    }
    New-Item -ItemType Directory -Force -Path $redistRoot | Out-Null

    Write-Host "Downloading the Microsoft Visual C++ 2015 Update 3 $Architecture redistributable."
    Invoke-WebRequest -Uri $redistUrl -OutFile $redistExe
    $signature = Get-AuthenticodeSignature $redistExe
    if ($signature.Status -ne "Valid" -or $signature.SignerCertificate.Subject -notmatch "Microsoft") {
        throw "The VC140 redistributable does not have a valid Microsoft signature."
    }

    $dark = (Get-Command "dark.exe" -ErrorAction Stop).Source
    & $dark -nologo -x $redistLayout $redistExe
    if ($LASTEXITCODE -ne 0) {
        throw "Extracting the VC140 redistributable bundle failed with exit code $LASTEXITCODE."
    }

    $minimumMsi = Get-ChildItem $redistLayout -Filter "vc_runtimeMinimum_$Architecture.msi" `
        -File -Recurse | Select-Object -First 1
    if (!$minimumMsi) {
        throw "The VC140 $Architecture minimum-runtime MSI was not found in the redistributable layout."
    }

    New-Item -ItemType Directory -Force -Path $redistExtract | Out-Null
    $msiProcess = Start-Process -FilePath "msiexec.exe" -ArgumentList @(
        "/a", "`"$($minimumMsi.FullName)`"", "/qn", "TARGETDIR=`"$redistExtract`""
    ) -Wait -PassThru
    if ($msiProcess.ExitCode -notin @(0, 3010)) {
        throw "Extracting the VC140 minimum-runtime MSI failed with exit code $($msiProcess.ExitCode)."
    }

    return Get-ChildItem $redistExtract -Filter "vcruntime140.dll" -File -Recurse |
        Select-Object -First 1
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
if (Test-Path $packageDirectory) {
    Remove-Item -Recurse -Force $packageDirectory
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

$ucrtFiles = $expectedHashes.Keys | Where-Object { $_ -ne "vcruntime140.dll" }
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

# The current VC runtime has a Windows 7 floor.  Locate the runtime installed
# with the v140 toolset and replace the copy selected by the normal build.
$visualStudioRoot = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio"
$vc140Runtimes = Get-ChildItem $visualStudioRoot -Filter "vcruntime140.dll" -File -Recurse |
    Where-Object {
        $_.FullName -match "Microsoft\.VC141\.CRT" -and
        $_.FullName -match "\\$sdkArch\\"
    } |
    Sort-Object FullName
$vc140Runtime = $vc140Runtimes | Where-Object {
    Test-ExpectedHash $_.FullName $expectedHashes["vcruntime140.dll"]
} | Select-Object -First 1

if (!$vc140Runtime) {
    Write-Host "VC141 runtime candidates for $sdkArch:"
    $vc140Runtimes | ForEach-Object {
        $hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        Write-Host "  $($_.VersionInfo.FileVersion) $hash $($_.FullName)"
    }
}
if (!$vc140Runtime -or !(Test-ExpectedHash $vc140Runtime.FullName $expectedHashes["vcruntime140.dll"])) {
    throw "Could not locate the reviewed $sdkArch Microsoft.VC141.CRT runtime. Pin a reviewed XP-compatible candidate; do not downgrade it to VC140."
}
$vc140VersionMatch = [regex]::Match($vc140Runtime.VersionInfo.FileVersion, "^\d+\.\d+\.\d+\.\d+")
if (!$vc140VersionMatch.Success) {
    throw "Could not parse the VC140 runtime version at $($vc140Runtime.FullName)."
}
$vc140Version = [Version]$vc140VersionMatch.Value
if ($vc140Version.Major -ne 14 -or $vc140Version.Minor -ne 0) {
    throw "Expected a 14.0 VC140 runtime, found $vc140Version at $($vc140Runtime.FullName)."
}
Copy-Item $vc140Runtime.FullName $packageDirectory -Force

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

if (Test-Path $packageZip) {
    Remove-Item -Force $packageZip
}
Compress-Archive -Path (Join-Path $packageDirectory "*") -DestinationPath $packageZip
Write-Host "Created $packageZip"