#Requires -Version 5.1
<#
.SYNOPSIS
  Installer for steam-desktop-startup-movies (Windows port).
.DESCRIPTION
  Mirrors install.sh: clones/pulls the plugin into
  C:\Program Files (x86)\Steam\millennium\plugins\startup-movies,
  ensures movies/thumbs exist, and builds the frontend if needed.
.PARAMETER Dir
  Custom plugin dir (default: "$Env:ProgramFiles(x86)\Steam\millennium\plugins\startup-movies").
.PARAMETER Rebuild
  Force npm rebuild (default: use shipped frontend/index.js).
.PARAMETER NoBuild
  Deprecated, kept for compat (skip-by-default now).
.PARAMETER Release
  Install from a prebuilt zip URL (no git/node needed).
.PARAMETER Branch
  Git branch to checkout (default: master).
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install.ps1
#>
[CmdletBinding()]
param(
    [string]$Dir = "",
    [switch]$Rebuild,
    [switch]$NoBuild,
    [string]$Release = "",
    [string]$Branch = "master"
)

$ErrorActionPreference = "Stop"
$Repo = "https://github.com/tuan-cre/steam-desktop-startup-movies.git"
$PluginName = "startup-movies"

if ([string]::IsNullOrWhiteSpace($Dir)) {
    $steamRoot = "${Env:ProgramFiles(x86)}\Steam"
    if (-not (Test-Path $steamRoot)) {
        # Fallback: 32-bit Steam on 64-bit Windows is the norm;ऐ
        $steamRoot = "$Env:ProgramFiles\Steam"
    }
    $Dir = Join-Path $steamRoot "millennium\plugins\$PluginName"
}

Write-Host "=== Startup Movies installer (Windows) ==="
Write-Host "Target: $Dir"

$millenniumMissing = (-not (Test-Path "${Env:ProgramFiles(x86)}\Steam\millennium")) -and (-not (Test-Path "$Env:ProgramFiles\Steam\millennium"))
if ($millenniumMissing) {
    Write-Warning "Millennium not found (<Steam>\millennium). Install first: https://steambrew.app/"
}

# --- Media serving (Windows): movies embed as data URLs, no python needed ---
# Only ffmpeg is optional (thumbnail generation).
Write-Host "serving: embedded data URLs (no server, no python required)"

if ($Release -ne "") {
    Write-Host "Installing from release zip: $Release"
    $tmpZip = Join-Path $env:TEMP ("startup-movies-" + [guid]::NewGuid().ToString("N") + ".zip")
    $tmpDir = Join-Path $env:TEMP ("startup-movies-" + [guid]::NewGuid().ToString("N"))
    try {
        Invoke-WebRequest -Uri $Release -OutFile $tmpZip
        Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force
        $sub = Get-ChildItem $tmpDir -Directory
        $src = if ($sub.Count -eq 1) { $sub[0].FullName } else { $tmpDir }
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
        Copy-Item (Join-Path $src "*") $Dir -Recurse -Force
        New-Item -ItemType Directory -Force -Path (Join-Path $Dir "movies\thumbs") | Out-Null
        New-Item -ItemType File -Force -Path (Join-Path $Dir "movies\.keep") -ErrorAction SilentlyContinue | Out-Null
        Write-Host "Installed prebuilt release to $Dir"
    } finally {
        Remove-Item $tmpZip -ErrorAction SilentlyContinue
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    if (Test-Path (Join-Path $Dir ".git")) {
        Write-Host "Existing install found, pulling $Branch ..."
        & git -C $Dir fetch origin $Branch --depth 1 2>$null
        if ($LASTEXITCODE -ne 0) { & git -C $Dir fetch origin }
        & git -C $Dir checkout $Branch 2>$null
        & git -C $Dir pull --ff-only origin $Branch
        if ($LASTEXITCODE -ne 0) { Write-Warning "pull failed" }
    } else {
        if ((Test-Path $Dir) -and (-not (Test-Path (Join-Path $Dir ".git")))) {
            $bak = "$Dir.bak." + [int][double]::Parse((Get-Date -UFormat %s))
            Write-Host "Backing up non-git dir to $bak"
            Move-Item $Dir $bak
        }
        Write-Host "Cloning $Repo ($Branch) ..."
        & git clone --depth 1 --branch $Branch $Repo $Dir
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $Dir "movies\thumbs") | Out-Null

    $indexJs = Join-Path $Dir "frontend\index.js"
    if ($Rebuild) {
        if (Get-Command npm -ErrorAction SilentlyContinue) {
            Write-Host "Rebuilding frontend (npm run build) ..."
            Push-Location $Dir
            try {
                & npm install --silent 2>&1 | Select-Object -Last 5
                & npm run build 2>&1 | Select-Object -Last 20
            } finally { Pop-Location }
            Write-Host ("Build done: " + (Get-Item $indexJs).Length + " bytes")
        } else {
            throw "npm missing - cannot rebuild"
        }
    } elseif (-not (Test-Path $indexJs)) {
        Write-Warning "frontend/index.js missing - re-run with -Rebuild (needs npm)"
    } else {
        Write-Host "Frontend prebuilt, skip build (use -Rebuild to force)"
    }
}

# --- Enable the plugin (Millennium keeps enabledPlugins in config.json) ---
# Steam must be closed: Millennium rewrites this file on exit/shutdown,
# which would clobber an edit made while it runs.
$steamProc = Get-Process steam -ErrorAction SilentlyContinue
if ($steamProc) {
    Write-Warning "Steam is running - skipping auto-enable (close Steam and re-run, or enable manually in Millennium settings)."
} else {
    $millenniumConfig = $null
    foreach ($root in @("${Env:ProgramFiles(x86)}\Steam", "$Env:ProgramFiles\Steam")) {
        $cand = Join-Path $root "millennium\config\config.json"
        if (Test-Path $cand) { $millenniumConfig = $cand; break }
    }
    if ($millenniumConfig) {
        try {
            Copy-Item $millenniumConfig "$millenniumConfig.bak" -Force
            $cfg = Get-Content $millenniumConfig -Raw | ConvertFrom-Json
            if ($null -eq $cfg.plugins) { $cfg | Add-Member -NotePropertyName plugins -NotePropertyValue (@{}) }
            if ($null -eq $cfg.plugins.enabledPlugins) { $cfg.plugins | Add-Member -NotePropertyName enabledPlugins -NotePropertyValue (@()) }
            if ($cfg.plugins.enabledPlugins -notcontains $PluginName) {
                $cfg.plugins.enabledPlugins += $PluginName
                $cfg | ConvertTo-Json -Depth 10 | Set-Content $millenniumConfig -Encoding UTF8
                Write-Host "Enabled plugin '$PluginName' in Millennium config."
            } else {
                Write-Host "Plugin '$PluginName' already enabled."
            }
        } catch {
            Write-Warning "Auto-enable failed ($_) - enable manually in Millennium settings."
        }
    } else {
        Write-Warning "Millennium config not found - enable the plugin manually in settings."
    }
}

Write-Host ""
Write-Host "=== Done ==="
Write-Host "Plugin: $Dir"
Write-Host "Movies: $(Join-Path $Dir 'movies\') (video files)"
try { $ff = (Get-Command ffmpeg -ErrorAction Stop).Source; Write-Host "ffmpeg: $ff (thumbnails on)" } catch { Write-Host "ffmpeg: not found (optional)" }
Write-Host ""
Write-Host "Restart Steam to apply."
