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

$v140Install = & $vswhere -latest -products * `
    -requires "Microsoft.VisualStudio.Component.VC.140" `
    -property installationPath
if (!$v140Install) {
    Write-Host "Installing the MSVC v140 toolset into $installPath"
    $arguments = @(
        "modify"
        "--installPath", "`"$installPath`""
        "--add", "Microsoft.VisualStudio.Component.VC.140"
        "--quiet"
        "--norestart"
        "--nocache"
    )
    $process = Start-Process -FilePath $installer -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -notin @(0, 3010)) {
        throw "Visual Studio Installer failed with exit code $($process.ExitCode)."
    }
    $v140Install = & $vswhere -latest -products * `
        -requires "Microsoft.VisualStudio.Component.VC.140" `
        -property installationPath
}

if (!$v140Install) {
    throw "The v140 toolset was not found after installation."
}

Write-Host "MSVC v140 toolset is available."
