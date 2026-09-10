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
.PARAMETER NoBuild
  Skip npm build even if frontend/index.js is missing/stale.
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

$millenniumDir = Join-Path (Split-Path $Dir -Parent | Split-Path -Parent) ""
if ((-not (Test-Path "$Env:ProgramFiles(x86)\Steam\millennium")) -and (-not (Test-Path "$Env:ProgramFiles\Steam\millennium"))) {
    Write-Warning "Millennium not found (<Steam>\millennium). Install first: https://steambrew.app/"
}

# --- Python check (required on Windows: serves movies/ over http) ---
$pyOk = $false
foreach ($cmd in @("python", "py")) {
    try {
        $out = & $cmd -c "print(1)" 2>&1
        if (($out | Out-String).Trim() -eq "1") { $pyOk = $true; Write-Host "python: $cmd (http serving on)"; break }
    } catch {}
}
if (-not $pyOk) {
    Write-Warning "No working python found - install Python 3.12+ (winget install Python.Python.3.12) or the http server cannot start."
}

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
    $indexTsx = Join-Path $Dir "frontend\index.tsx"
    $needBuild = $false
    if (-not (Test-Path $indexJs)) { $needBuild = $true; Write-Host "frontend/index.js missing - build required" }
    elseif ((Get-Item $indexTsx).LastWriteTime -gt (Get-Item $indexJs).LastWriteTime) { $needBuild = $true; Write-Host "frontend/index.tsx newer - rebuild" }

    if ($needBuild -and (-not $NoBuild)) {
        if (Get-Command npm -ErrorAction SilentlyContinue) {
            Write-Host "Building frontend (npm run build) ..."
            Push-Location $Dir
            try {
                & npm install --silent 2>&1 | Select-Object -Last 5
                & npm run build 2>&1 | Select-Object -Last 20
            } finally { Pop-Location }
            Write-Host ("Build done: " + (Get-Item $indexJs).Length + " bytes")
        } else {
            Write-Warning "npm missing - run: cd `"$Dir`"; npm install; npm run build"
        }
    } else {
        Write-Host "Frontend built, skip build"
    }
}

Write-Host ""
Write-Host "=== Done ==="
Write-Host "Plugin: $Dir"
Write-Host "Movies: $(Join-Path $Dir 'movies\') (video files)"
try { $ff = (Get-Command ffmpeg -ErrorAction Stop).Source; Write-Host "ffmpeg: $ff (thumbnails on)" } catch { Write-Host "ffmpeg: not found (optional)" }
Write-Host ""
Write-Host "Restart Steam to apply."
