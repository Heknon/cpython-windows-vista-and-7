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

# Vista RTM cannot rely on the system Universal CRT update.  Copy the UCRT
# API-set forwarders and ucrtbase.dll beside python.exe for app-local loading.
$ucrtDirectories = Get-ChildItem (Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\Redist") `
    -Directory -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "\\ucrt\\DLLs\\$sdkArch$" } |
    Sort-Object FullName -Descending

$ucrtDirectory = $ucrtDirectories | Select-Object -First 1
if (!$ucrtDirectory) {
    throw "Could not locate an app-local UCRT directory for $sdkArch."
}
Copy-Item (Join-Path $ucrtDirectory.FullName "*.dll") $packageDirectory -Force

# The current VC runtime has a Windows 7 floor.  Locate the runtime installed
# with the v140 toolset and replace the copy selected by the normal build.
$visualStudioRoot = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio"
$vc140Runtime = Get-ChildItem $visualStudioRoot -Filter "vcruntime140.dll" -File -Recurse |
    Where-Object {
        $_.FullName -match "Microsoft\.VC140\.CRT" -and
        $_.FullName -match "\\$sdkArch\\"
    } |
    Sort-Object FullName |
    Select-Object -First 1

if (!$vc140Runtime) {
    $vc140Runtime = Get-Vc140RuntimeFromRedist -Architecture $sdkArch
}
if (!$vc140Runtime) {
    throw "Could not locate or extract the $sdkArch Microsoft.VC140.CRT runtime."
}
$vc140Version = [Version]$vc140Runtime.VersionInfo.FileVersion
if ($vc140Version.Major -ne 14 -or $vc140Version.Minor -ne 0) {
    throw "Expected a 14.0 VC140 runtime, found $vc140Version at $($vc140Runtime.FullName)."
}
Copy-Item $vc140Runtime.FullName $packageDirectory -Force

if (Test-Path $packageZip) {
    Remove-Item -Force $packageZip
}
Compress-Archive -Path (Join-Path $packageDirectory "*") -DestinationPath $packageZip
Write-Host "Created $packageZip"
