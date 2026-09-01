#!/usr/bin/env pwsh
# One-liner installer for steam-desktop-startup-movies on Windows (FTP VFS, no python)
# Usage:
#   irm https://raw.githubusercontent.com/tuan-cre/steam-desktop-startup-movies/windows-support/scripts/install.ps1 | iex
#   pwsh scripts/install.ps1 [-Dir <path>] [-Release <zip-url>] [-NoBuild]
[CmdletBinding()]
param(
    [string]$Dir = "",
    [string]$Release = "",
    [switch]$NoBuild
)

$ErrorActionPreference = "Stop"

$Repo = "https://github.com/tuan-cre/steam-desktop-startup-movies.git"
$Branch = "windows-support"
$PluginName = "startup-movies"

if ([string]::IsNullOrEmpty($Dir)) {
    $Dir = Join-Path $env:LOCALAPPDATA "millennium\plugins\$PluginName"
}

Write-Host "=== Startup Movies installer (Windows, FTP VFS) ==="
Write-Host "Target: $Dir"

# --- build from source or release zip ---
function Invoke-GitClone([string]$target) {
    if (Test-Path (Join-Path $target ".git")) {
        Write-Host "Existing install found, pulling $Branch ..."
        Push-Location $target
        try { git fetch origin $Branch --depth 1; git checkout $Branch; git pull --ff-only origin $Branch }
        catch { Write-Host "WARN: git pull failed" }
        Pop-Location
    } else {
        if (Test-Path $target) {
            $bak = "$target.bak.$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
            Write-Host "Backing up non-git dir to $bak"
            Rename-Item $target $bak
        }
        Write-Host "Cloning $Repo ($Branch) ..."
        git clone --depth 1 --branch $Branch $Repo $target
    }
}

if (-not [string]::IsNullOrEmpty($Release)) {
    Write-Host "Installing from release zip: $Release"
    $tmp = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "startup-movies-$([guid]::NewGuid())")
    try {
        $zip = Join-Path $tmp "rel.zip"
        Invoke-WebRequest -Uri $Release -OutFile $zip
        Expand-Archive -Path $zip -DestinationPath $tmp -Force
        $src = Get-ChildItem $tmp -Directory | Select-Object -First 1
        if (-not $src) { $src = $tmp }
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
        Copy-Item "$($src.FullName)\*" $Dir -Recurse -Force
        New-Item -ItemType Directory -Force -Path (Join-Path $Dir "movies\thumbs") | Out-Null
        Write-Host "Installed prebuilt release to $Dir"
    } finally { Remove-Item $tmp -Recurse -Force }
} else {
    Invoke-GitClone $Dir
    New-Item -ItemType Directory -Force -Path (Join-Path $Dir "movies\thumbs") | Out-Null

    $needsBuild = -not (Test-Path (Join-Path $Dir "frontend\index.js"))
    if (-not $needsBuild) {
        $tsx = Join-Path $Dir "frontend\index.tsx"
        $js  = Join-Path $Dir "frontend\index.js"
        $needsBuild = (Test-Path $tsx) -and ((Get-Item $js).LastWriteTime -lt (Get-Item $tsx).LastWriteTime)
    }

    if ($needsBuild -and (-not $NoBuild)) {
        if (Get-Command npm -ErrorAction SilentlyContinue) {
            Write-Host "Building frontend (npm run build) ..."
            Push-Location $Dir
            try {
                npm install --silent | Out-Null
                npm run build
            } finally { Pop-Location }
            Write-Host "Build done: $((Get-Item (Join-Path $Dir 'frontend\index.js')).Length) bytes"
        } else {
            Write-Warning "npm missing - run: (cd '$Dir' && npm install && npm run build)"
        }
    } else {
        Write-Host "Frontend built, skip build"
    }
}

Write-Host ""
Write-Host "=== Done ==="
Write-Host "Plugin: $Dir"
Write-Host "Movies: $Dir\movies\ (.webm/.mp4)"
if (Get-Command ffmpeg -ErrorAction SilentlyContinue) {
    Write-Host "ffmpeg: $( (Get-Command ffmpeg).Source ) (thumbnails on)"
} else {
    Write-Host "ffmpeg: not found (optional, for thumbnails)"
}
Write-Host ""
Write-Host "NOTE: Windows build runs on stock Millennium with the muted-first hybrid audio fallback."
Write-Host "The Linux-only autoplay-patch (instant unmuted audio) does NOT yet apply on Windows."
Write-Host ""
Write-Host "Restart Steam to apply."
