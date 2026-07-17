[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
$installer = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\setup.exe"

if (!(Test-Path $vswhere) -or !(Test-Path $installer)) {
    throw "Visual Studio Installer and vswhere are required."
}

$installPath = & $vswhere -latest -products * -property installationPath
if (!$installPath) {
    throw "No Visual Studio installation was found."
}

$xpTargets = Get-ChildItem $installPath -Filter "Toolset.props" `
    -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "\\PlatformToolsets\\v141_xp\\Toolset\.props$" } |
    Select-Object -First 1
if (!$xpTargets) {
    Write-Host "Installing the MSVC v141_xp toolset into $installPath"
    $arguments = @(
        "modify"
        "--installPath", "`"$installPath`""
        "--add", "Microsoft.VisualStudio.Component.WinXP"
        "--quiet"
        "--norestart"
        "--nocache"
    )
    $process = Start-Process -FilePath $installer -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -notin @(0, 3010)) {
        throw "Visual Studio Installer failed with exit code $($process.ExitCode)."
    }
    $xpTargets = Get-ChildItem $installPath -Filter "Toolset.props" `
        -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "\\PlatformToolsets\\v141_xp\\Toolset\.props$" } |
        Select-Object -First 1
}

if (!$xpTargets) {
    throw "The v141_xp platform toolset was not found after installation."
}

$sdk71a = Get-ItemProperty `
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft SDKs\Windows\v7.1A" `
    -ErrorAction SilentlyContinue
if (!$sdk71a -or !(Test-Path $sdk71a.InstallationFolder)) {
    throw "The Windows 7.1A SDK required by v140_xp was not found."
}

Write-Host "MSVC v141_xp is available at $($xpTargets.FullName)."
Write-Host "Windows 7.1A SDK is available at $($sdk71a.InstallationFolder)."