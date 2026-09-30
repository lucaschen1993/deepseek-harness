# Prepare repository-local Windows build tools and launch the Desktop development profile.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$buildRoot = Join-Path $repoRoot 'apps/desktop/.desktop-build'
$toolsRoot = Join-Path $buildRoot 'bootstrap'
$logRoot = Join-Path $buildRoot 'logs'
$transcribing = $false
$setupLock = $null
$originalPath = $env:PATH
$originalDevtools = $env:DSH_DESKTOP_OPEN_DEVTOOLS
$originalElectronMode = $env:ELECTRON_RUN_AS_NODE

function Invoke-Checked {
    param([string]$Executable, [string[]]$Arguments)
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Executable failed with exit code $LASTEXITCODE. See the output above."
    }
}

try {
    if ($env:OS -ne 'Windows_NT' -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
        throw 'Desktop setup requires Windows x64 and 64-bit Windows PowerShell.'
    }
    if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
        throw 'Install Git for Windows, then run setup-desktop.cmd again.'
    }
    New-Item -ItemType Directory -Force -Path $toolsRoot, $logRoot | Out-Null
    # The handle also excludes a second setup launched from a different terminal.
    $setupLock = [IO.File]::Open((Join-Path $toolsRoot 'setup.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    $logPath = Join-Path $logRoot (('setup-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss')))
    Start-Transcript -LiteralPath $logPath | Out-Null
    $transcribing = $true
    Write-Host "Repository: $repoRoot"
    Write-Host "Log: $logPath"
    $running = Get-Process -Name electron -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and $_.Path.StartsWith(($repoRoot + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)
    }
    if ($running) { throw 'Close Desktop running from this repository, then run setup-desktop.cmd again.' }

    $manifest = Get-Content -LiteralPath (Join-Path $repoRoot 'package.json') -Raw | ConvertFrom-Json
    $runtimeLock = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts/primary-runtime/lock.json') -Raw | ConvertFrom-Json
    $nodeVersion = $runtimeLock.nodeVersion
    if ($nodeVersion -notmatch '^\d+\.\d+\.\d+$' -or $manifest.packageManager -notmatch '^pnpm@(\d+\.\d+\.\d+)$') {
        throw 'Desktop setup requires exact Node and pnpm versions in the repository manifests.'
    }
    $pnpmVersion = $Matches[1]
    $nodeFolder = "node-v$nodeVersion-win-x64"
    $nodeRoot = Join-Path $toolsRoot $nodeFolder
    $node = Join-Path $nodeRoot 'node.exe'
    $nodeReady = Join-Path $nodeRoot '.desktop-setup-ready'
    if (-not (Test-Path -LiteralPath $nodeReady)) {
        Write-Host "[1/4] Downloading Node $nodeVersion from nodejs.org..."
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $archive = Join-Path $toolsRoot "$nodeFolder.zip"
        Invoke-WebRequest -UseBasicParsing -Uri "https://nodejs.org/dist/v$nodeVersion/$nodeFolder.zip" -OutFile $archive
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $runtimeLock.targets.'win-x64'.nodeSha256) {
            throw 'Node archive checksum does not match scripts/primary-runtime/lock.json. Run setup again to retry the download.'
        }
        Expand-Archive -LiteralPath $archive -DestinationPath $toolsRoot -Force
        New-Item -ItemType File -Force -Path $nodeReady | Out-Null
    }
    $actualNodeVersion = & $node --version
    if ($LASTEXITCODE -ne 0 -or $actualNodeVersion -ne "v$nodeVersion") { throw "Node $nodeVersion is unavailable at $node." }
    $env:PATH = "$nodeRoot;$originalPath"
    $pnpmRoot = Join-Path $toolsRoot "pnpm-$pnpmVersion"
    $pnpm = Join-Path $pnpmRoot 'node_modules/pnpm/bin/pnpm.cjs'
    $pnpmReady = Join-Path $pnpmRoot '.desktop-setup-ready'
    if (-not (Test-Path -LiteralPath $pnpmReady)) {
        Write-Host "[2/4] Installing pnpm $pnpmVersion from the configured npm registry..."
        Invoke-Checked $node @((Join-Path $nodeRoot 'node_modules/npm/bin/npm-cli.js'), 'install', '--prefix', $pnpmRoot,
            '--ignore-scripts', '--no-audit', '--no-fund', '--package-lock=false', "pnpm@$pnpmVersion")
        New-Item -ItemType File -Force -Path $pnpmReady | Out-Null
    }
    $actualPnpmVersion = & $node $pnpm --version
    if ($LASTEXITCODE -ne 0 -or $actualPnpmVersion -ne $pnpmVersion) { throw "pnpm $pnpmVersion is unavailable at $pnpm." }
    $env:PATH = "$(Join-Path $pnpmRoot 'node_modules/.bin');$env:PATH"
    Push-Location -LiteralPath $repoRoot
    try {
        Write-Host '[3/4] Installing workspace dependencies from pnpm-lock.yaml...'
        Invoke-Checked $node @($pnpm, 'install', '--frozen-lockfile')
        Write-Host '[4/4] Building and starting Desktop. First launch downloads Python and Office dependencies.'
        if (-not $env:DSH_DESKTOP_OPEN_DEVTOOLS) { $env:DSH_DESKTOP_OPEN_DEVTOOLS = '0' }
        $env:ELECTRON_RUN_AS_NODE = $null
        Invoke-Checked $node @($pnpm, 'run', 'dev:desktop')
    } finally {
        Pop-Location
    }
} catch {
    Write-Host "Desktop setup failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    $env:PATH = $originalPath
    $env:DSH_DESKTOP_OPEN_DEVTOOLS = $originalDevtools
    $env:ELECTRON_RUN_AS_NODE = $originalElectronMode
    if ($transcribing) { Stop-Transcript | Out-Null }
    if ($null -ne $setupLock) { $setupLock.Dispose() }
}
