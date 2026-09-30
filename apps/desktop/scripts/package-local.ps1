# Prepare native build prerequisites and delegate unsigned packaging to the existing release pipeline.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Node, [Parameter(Mandatory=$true)][string]$Pnpm)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$originalPython = $env:PYTHON
$originalNpmPython = $env:npm_config_python

function Invoke-PackageCommand {
    param([string[]]$Arguments)
    & $Node $Pnpm @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Desktop packaging command failed with exit code $LASTEXITCODE. See the output above." }
}

Push-Location -LiteralPath $repoRoot
try {
    # Validate file-owned service settings before installing machine-wide build tools.
    $validate = @'
import { loadDesktopPackageEnvironment, validateDesktopPackageEnvironment } from './apps/desktop/scripts/desktop-package-environment.mjs';
validateDesktopPackageEnvironment(loadDesktopPackageEnvironment('win32'), { platform: 'win32', arch: 'x64' }, { unsigned: true });
'@
    & $Node --input-type=module -e $validate
    if ($LASTEXITCODE -ne 0) { throw 'Correct apps/desktop/.env.windows, then run package-desktop.cmd again.' }

    $product = Get-Content -LiteralPath (Join-Path $repoRoot 'apps/desktop/package.json') -Raw | ConvertFrom-Json
    $buildVersion = Read-Host "Unsigned EXE build version (current product: $($product.version)); enter the complete version to confirm"
    if ([string]::IsNullOrWhiteSpace($buildVersion)) { throw 'No build version confirmed. Packaging cancelled.' }
    $validateVersion = @'
import { validateDesktopBuildVersion } from './apps/desktop/scripts/desktop-build-version.mjs';
console.log(validateDesktopBuildVersion(process.argv[1], process.argv[2]));
'@
    $normalizedVersion = & $Node --input-type=module -e $validateVersion $buildVersion $product.version
    if ($LASTEXITCODE -ne 0) { throw 'Invalid build version. Use the version rules in apps/desktop/README.md.' }
    $buildVersion = $normalizedVersion

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $visualStudio = if (Test-Path -LiteralPath $vswhere) {
        & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    } else { $null }
    if (-not $visualStudio) {
        if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
            throw 'Install Windows App Installer (winget), or Visual Studio Build Tools with Desktop development with C++, then retry.'
        }
        Write-Host 'Installing Visual Studio 2022 C++ Build Tools. Windows may request administrator permission.'
        & winget.exe install --id Microsoft.VisualStudio.2022.BuildTools --exact --source winget --override '--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
        if ($LASTEXITCODE -ne 0) { throw "Build Tools installation exited with $LASTEXITCODE. Complete installation or restart Windows if requested, then retry." }
    }

    Write-Host 'Preparing the pinned Python runtime for native module compilation...'
    Invoke-PackageCommand @('--dir', 'apps/desktop', 'run', 'prepare:primary-runtime')
    $env:PYTHON = Join-Path $repoRoot 'apps/desktop/.desktop-build/targets/win-x64/runtime/primary-runtime/dependencies/python/python.exe'
    if (-not (Test-Path -LiteralPath $env:PYTHON)) { throw "Prepared Python executable is missing: $env:PYTHON" }
    $env:npm_config_python = $env:PYTHON
    Invoke-PackageCommand @('--dir', 'apps/desktop', 'run', 'package:win:x64:unsigned', '--check', '--build-version', $buildVersion)
    Write-Host '[4/4] Building the unsigned Windows installer...'
    Invoke-PackageCommand @('run', 'package:desktop:win:x64:unsigned', '--build-version', $buildVersion)
    $artifacts = Join-Path $repoRoot 'apps/desktop/.desktop-build/targets/win-x64/unsigned-artifacts'
    $installer = Join-Path $artifacts "deepseek-harness-$buildVersion-win-x64-unsigned.exe"
    if (-not (Test-Path -LiteralPath $installer)) { throw "Packaging returned without the expected installer: $installer" }
    Write-Host "Installer ready: $installer"
} finally {
    $env:PYTHON = $originalPython
    $env:npm_config_python = $originalNpmPython
    Pop-Location
}
