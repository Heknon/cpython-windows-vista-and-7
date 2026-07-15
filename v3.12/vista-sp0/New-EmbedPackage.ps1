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
    throw "Could not locate the $sdkArch Microsoft.VC140.CRT runtime."
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
