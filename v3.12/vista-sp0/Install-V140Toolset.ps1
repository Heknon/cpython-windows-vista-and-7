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
$v141Tools = Get-ChildItem (Join-Path $installPath "VC\Tools\MSVC") `
    -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match "^14\.16\." } |
    Sort-Object Name -Descending |
    Select-Object -First 1
$v141Redist = Get-ChildItem (Join-Path $installPath "VC\Redist\MSVC") `
    -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match "^14\.16\." } |
    Sort-Object Name -Descending |
    Select-Object -First 1
if (!$xpTargets -or !$v141Tools -or !$v141Redist) {
    Write-Host "Installing the MSVC v141_xp toolset into $installPath"
    $arguments = @(
        "modify"
        "--installPath", "`"$installPath`""
        "--add", "Microsoft.VisualStudio.Component.VC.v141.x86.x64"
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
    $v141Tools = Get-ChildItem (Join-Path $installPath "VC\Tools\MSVC") `
        -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "^14\.16\." } |
        Sort-Object Name -Descending |
        Select-Object -First 1
    $v141Redist = Get-ChildItem (Join-Path $installPath "VC\Redist\MSVC") `
        -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "^14\.16\." } |
        Sort-Object Name -Descending |
        Select-Object -First 1
}

if (!$xpTargets) {
    throw "The v141_xp platform toolset was not found after installation."
}
if (!$v141Tools) {
    throw "The MSVC v141 14.16 compiler and linker were not found after installation."
}
if (!$v141Redist) {
    throw "The MSVC v141 14.16 redistributable payload was not found after installation."
}

$sdk71a = Get-ItemProperty `
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft SDKs\Windows\v7.1A" `
    -ErrorAction SilentlyContinue
if (!$sdk71a -or !(Test-Path $sdk71a.InstallationFolder)) {
    throw "The Windows 7.1A SDK required by v141_xp was not found."
}

Write-Host "MSVC v141_xp is available at $($xpTargets.FullName)."
Write-Host "MSVC v141 tools are available at $($v141Tools.FullName)."
Write-Host "MSVC v141 redistributables are available at $($v141Redist.FullName)."
Write-Host "Windows 7.1A SDK is available at $($sdk71a.InstallationFolder)."

"V141_TOOLS_VERSION=$($v141Tools.Name)" | Out-File `
    -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
"V141_REDIST_ROOT=$($v141Redist.FullName)" | Out-File `
    -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
