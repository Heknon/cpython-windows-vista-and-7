[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("x64", "Win32")]
    [string]$Platform,

    [Parameter(Mandatory = $true)]
    [string]$PackageDirectory
)

$ErrorActionPreference = "Stop"

$packageDirectory = [IO.Path]::GetFullPath($PackageDirectory)
if (!(Test-Path $packageDirectory -PathType Container)) {
    throw "Package directory does not exist: $packageDirectory"
}

$requirements = Join-Path $PSScriptRoot "ThirdPartyRequirements.txt"
$win32Requirements = Join-Path $PSScriptRoot "ThirdPartyRequirements-Win32.txt"
$requirementFiles = @($requirements)
if ($Platform -eq "Win32") {
    $requirementFiles += $win32Requirements
}
$target = Join-Path $packageDirectory "validation-packages"
$pipPlatform = if ($Platform -eq "x64") { "win_amd64" } else { "win32" }
$installerPython = (Get-Command python -ErrorAction Stop).Source

if (Test-Path $target) {
    Remove-Item $target -Recurse -Force
}
New-Item $target -ItemType Directory -Force | Out-Null

# The validation wheels are deliberately separate from the embeddable
# interpreter's default sys.path.  pip is only an assembly tool here: exact
# versions and every transitive dependency are listed and hash-pinned.
$pipArguments = @(
    "-m", "pip", "install"
    "--disable-pip-version-check"
    "--no-compile"
    "--no-deps"
    "--only-binary=:all:"
    "--require-hashes"
    "--implementation", "cp"
    "--python-version", "3.12"
    "--abi", "cp312"
    "--platform", $pipPlatform
    "--target", $target
)
foreach ($requirementFile in $requirementFiles) {
    $pipArguments += @("--requirement", $requirementFile)
}
& $installerPython @pipArguments
if ($LASTEXITCODE -ne 0) {
    throw "Installing the pinned $pipPlatform validation wheels failed with exit code $LASTEXITCODE."
}

$expectedDistributions = @(
    "plumbum-1.9.0.dist-info"
    "psutil-7.0.0.dist-info"
    "rpyc-6.0.2.dist-info"
)
if ($Platform -eq "Win32") {
    $expectedDistributions += "pywin32-307.dist-info"
    $expectedDistributions = @($expectedDistributions | Sort-Object)
}
$actualDistributions = @(
    Get-ChildItem $target -Directory -Filter "*.dist-info" |
        ForEach-Object { $_.Name } |
        Sort-Object
)
if (Compare-Object $expectedDistributions $actualDistributions) {
    throw "The installed validation distribution set does not match the reviewed package matrix."
}

$pywin32DllDirectory = Join-Path $target "pywin32_system32"
if ($Platform -eq "Win32" -and
        !(Test-Path $pywin32DllDirectory -PathType Container)) {
    throw "The Win32 pywin32 private DLL directory is missing."
}

Copy-Item $requirements (Join-Path $packageDirectory "THIRD-PARTY-REQUIREMENTS.txt") -Force
if ($Platform -eq "Win32") {
    Copy-Item $win32Requirements `
        (Join-Path $packageDirectory "THIRD-PARTY-REQUIREMENTS-WIN32.txt") -Force
}
Write-Host "Installed the pinned third-party validation matrix for $pipPlatform."
