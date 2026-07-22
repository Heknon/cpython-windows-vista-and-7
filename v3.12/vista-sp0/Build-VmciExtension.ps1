[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("x64", "Win32")]
    [string]$Platform
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$sourceRoot = Join-Path $repoRoot "v3.12\Python-3.12.10"
$buildArch = if ($Platform -eq "x64") { "amd64" } else { "win32" }
$buildDirectory = Join-Path $sourceRoot "PCbuild\$buildArch"
$project = Join-Path $PSScriptRoot "vmci\vmci.vcxproj"
$toolsVersion = $env:V141_TOOLS_VERSION

if (!(Test-Path (Join-Path $buildDirectory "python312.lib"))) {
    throw "Build CPython before building the VMCI extension."
}
if (!$toolsVersion -or $toolsVersion -notmatch "^14\.16\.") {
    throw "V141_TOOLS_VERSION must identify the reviewed MSVC 14.16 toolset."
}

& msbuild.exe $project `
    /m `
    /t:Build `
    /p:Configuration=Release `
    /p:Platform=$Platform `
    /p:PlatformToolset=v141_xp `
    /p:VCToolsVersion=$toolsVersion `
    /p:WindowsTargetPlatformVersion=7.0 `
    /p:PythonSourceRoot=$sourceRoot `
    /p:PythonBuildDir=$buildDirectory
if ($LASTEXITCODE -ne 0) {
    throw "Building _vmci.pyd failed with exit code $LASTEXITCODE."
}

Write-Host "Created $(Join-Path $buildDirectory '_vmci.pyd')"
