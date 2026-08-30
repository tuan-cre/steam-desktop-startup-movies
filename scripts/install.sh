#!/usr/bin/env bash
# One-liner installer for steam-desktop-startup-movies + patched Millennium (FTP VFS stable)
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/tuan-cre/steam-desktop-startup-movies/master/scripts/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --no-patch   # skip Millennium patch
#   bash scripts/install.sh [--dir <path>] [--no-build] [--release <zip-url>] [--no-patch]
set -euo pipefail

REPO="https://github.com/tuan-cre/steam-desktop-startup-movies.git"
BRANCH="master"
PLUGIN_NAME="startup-movies"

INSTALL_DIR=""
NO_BUILD=0
RELEASE_URL=""
WITH_PATCH=1  # default: patch Millennium for FTP stability (no freeze)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir) INSTALL_DIR="$2"; shift 2 ;;
        --no-build) NO_BUILD=1; shift ;;
        --release) RELEASE_URL="$2"; shift 2 ;;
        --branch) BRANCH="$2"; shift 2 ;;
        --no-patch|--without-patch) WITH_PATCH=0; shift ;;
        --patch|--with-patch) WITH_PATCH=1; shift ;;
        -h|--help)
            echo "Usage: install.sh [--dir <path>] [--no-build] [--release <zip-url>] [--branch <branch>] [--no-patch]"
            echo "  --dir      Custom plugin dir (default: \$XDG_DATA_HOME/millennium/plugins/$PLUGIN_NAME)"
            echo "  --no-build Skip npm build if frontend/index.js missing"
            echo "  --release  Install from prebuilt zip (no git/node)"
            echo "  --no-patch Skip Millennium autoplay patch (FTP may freeze every-other on stock 3.4.1)"
            exit 0
            ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$INSTALL_DIR" ]]; then
    XDG_DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
    INSTALL_DIR="$XDG_DATA/millennium/plugins/$PLUGIN_NAME"
fi

echo "=== Startup Movies installer (FTP VFS + Millennium patch) ==="
echo "Target: $INSTALL_DIR"

if [[ ! -d "${XDG_DATA_HOME:-$HOME/.local/share}/millennium" && ! -d "$HOME/.millennium" ]]; then
    echo "WARN: Millennium not found (~/.local/share/millennium). Install first: https://steambrew.app/"
fi

if [[ -n "$RELEASE_URL" ]]; then
    echo "Installing from release zip: $RELEASE_URL"
    tmpzip="$(mktemp /tmp/startup-movies-XXXXXX.zip)"
    tmpdir="$(mktemp -d /tmp/startup-movies-XXXXXX)"
    trap 'rm -rf "$tmpzip" "$tmpdir"' EXIT
    curl -fsSL "$RELEASE_URL" -o "$tmpzip"
    unzip -q "$tmpzip" -d "$tmpdir"
    src="$tmpdir"
    if [[ $(find "$tmpdir" -maxdepth 1 -type d | wc -l) -eq 2 ]]; then
        src="$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d | head -1)"
    fi
    mkdir -p "$INSTALL_DIR"
    cp -r "$src"/. "$INSTALL_DIR"/
    mkdir -p "$INSTALL_DIR/movies/thumbs"
    touch "$INSTALL_DIR/movies/.keep" 2>/dev/null || true
    echo "Installed prebuilt release to $INSTALL_DIR"
else
    if [[ -d "$INSTALL_DIR/.git" ]]; then
        echo "Existing install found, pulling $BRANCH ..."
        git -C "$INSTALL_DIR" fetch origin "$BRANCH" --depth 1 2>/dev/null || git -C "$INSTALL_DIR" fetch origin
        git -C "$INSTALL_DIR" checkout "$BRANCH" 2>/dev/null || true
        git -C "$INSTALL_DIR" pull --ff-only origin "$BRANCH" || echo "WARN: pull failed"
    else
        if [[ -e "$INSTALL_DIR" && ! -d "$INSTALL_DIR/.git" ]]; then
            echo "Backing up non-git dir to ${INSTALL_DIR}.bak.$(date +%s)"
            mv "$INSTALL_DIR" "${INSTALL_DIR}.bak.$(date +%s)"
        fi
        echo "Cloning $REPO ($BRANCH) ..."
        git clone --depth 1 --branch "$BRANCH" "$REPO" "$INSTALL_DIR"
    fi
    mkdir -p "$INSTALL_DIR/movies/thumbs"
    need_build=0
    if [[ ! -f "$INSTALL_DIR/frontend/index.js" ]]; then
        need_build=1; echo "frontend/index.js missing - build required"
    elif [[ "$INSTALL_DIR/frontend/index.tsx" -nt "$INSTALL_DIR/frontend/index.js" ]]; then
        need_build=1; echo "frontend/index.tsx newer - rebuild"
    fi
    if [[ $need_build -eq 1 && $NO_BUILD -eq 0 ]]; then
        if command -v npm >/dev/null 2>&1; then
            echo "Building frontend (npm run build) ..."
            (cd "$INSTALL_DIR" && npm install --silent 2>&1 | tail -5; npm run build 2>&1 | tail -20)
            echo "Build done: $(wc -c < "$INSTALL_DIR/frontend/index.js") bytes"
        else
            echo "WARN: npm missing - run: (cd \"$INSTALL_DIR\" && npm install && npm run build)"
        fi
    else
        echo "Frontend built, skip build"
    fi
fi

# --- Millennium autoplay patch (required for FTP VFS no-freeze on 3.4.1 stock) ---
if [[ $WITH_PATCH -eq 0 ]]; then
    echo ""
    echo "Skipping Millennium patch (--no-patch). FTP may freeze every-other on stock 3.4.1 (http_hooks.cc:314 timeout / reload 37:48)."
else
    echo ""
    echo "=== Millennium patch check (FTP requires --autoplay-policy) ==="
    if grep -q "autoplay-policy" /usr/lib/millennium/libmillennium_x86.so 2>/dev/null; then
        echo "Already patched (autoplay-policy in /usr/lib/millennium/libmillennium_x86.so), skipping build."
    else
        # also check running steamwebhelper cmdline
        if ps aux 2>/dev/null | grep -q "autoplay-policy"; then
            echo "Running steamwebhelper already has autoplay-policy, skipping."
        else
            echo "Stock Millennium detected — patching for stable FTP (video muted-first hybrid + instant audio)..."
            # prefer local patch script if present (installed plugin or repo)
            PATCH_SCRIPT=""
            if [[ -f "$INSTALL_DIR/scripts/patch-millennium.sh" ]]; then
                PATCH_SCRIPT="$INSTALL_DIR/scripts/patch-millennium.sh"
            elif [[ -f "$(dirname "$0")/patch-millennium.sh" ]]; then
                PATCH_SCRIPT="$(dirname "$0")/patch-millennium.sh"
            fi
            if [[ -n "$PATCH_SCRIPT" && -f "$PATCH_SCRIPT" ]]; then
                echo "Running $PATCH_SCRIPT ..."
                bash "$PATCH_SCRIPT" || echo "WARN: patch script failed, continue anyway"
            else
                echo "Fetching patch script..."
                curl -fsSL https://raw.githubusercontent.com/tuan-cre/steam-desktop-startup-movies/master/scripts/patch-millennium.sh | bash || echo "WARN: fetch patch failed"
            fi
        fi
    fi
fi

echo ""
echo "=== Done ==="
echo "Plugin: $INSTALL_DIR"
echo "Movies: $INSTALL_DIR/movies/ (.webm/.mp4)"
command -v ffmpeg >/dev/null 2>&1 && echo "ffmpeg: $(which ffmpeg) (thumbnails on)" || echo "ffmpeg: not found (optional)"
echo "Millennium: $(grep -q autoplay-policy /usr/lib/millennium/libmillennium_x86.so 2>/dev/null && echo "patched (stable FTP)" || echo "stock (FTP may freeze — re-run with --patch)")"
echo ""
echo "Restart Steam to apply. Verify: grep startup-movies ~/.local/share/Steam/logs/millennium.log | tail -5"
