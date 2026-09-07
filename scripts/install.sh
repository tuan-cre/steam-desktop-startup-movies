#!/usr/bin/env bash
# One-liner installer for steam-desktop-startup-movies
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/tuan-cre/steam-desktop-startup-movies/master/scripts/install.sh | bash
#   bash scripts/install.sh [--dir <path>] [--no-build] [--release <zip-url>]
set -euo pipefail

REPO="https://github.com/tuan-cre/steam-desktop-startup-movies.git"
BRANCH="master"
PLUGIN_NAME="startup-movies"

INSTALL_DIR=""
NO_BUILD=0
RELEASE_URL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir) INSTALL_DIR="$2"; shift 2 ;;
        --no-build) NO_BUILD=1; shift ;;
        --release) RELEASE_URL="$2"; shift 2 ;;
        --branch) BRANCH="$2"; shift 2 ;;
        # Deprecated patch flags: accepted for compatibility, patching is always skipped
        # (recent Steam ships --autoplay-policy stock).
        --no-patch|--without-patch) shift ;;
        --patch|--with-patch) echo "NOTE: --patch is deprecated (Steam ships --autoplay-policy stock now). Ignoring."; shift ;;
        -h|--help)
            echo "Usage: install.sh [--dir <path>] [--no-build] [--release <zip-url>] [--branch <branch>]"
            echo "  --dir      Custom plugin dir (default: \$XDG_DATA_HOME/millennium/plugins/$PLUGIN_NAME)"
            echo "  --no-build Skip npm build if frontend/index.js missing"
            echo "  --release  Install from prebuilt zip (no git/node)"
            echo "  --no-patch Accepted for compatibility (patching is deprecated, always skipped)"
            exit 0
            ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$INSTALL_DIR" ]]; then
    XDG_DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
    INSTALL_DIR="$XDG_DATA/millennium/plugins/$PLUGIN_NAME"
fi

echo "=== Startup Movies installer ==="
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

# --- Millennium autoplay patch (DEPRECATED: Steam ships --autoplay-policy stock) ---
echo ""
echo "Skipping Millennium patch (deprecated - not needed on recent Steam)."

echo ""
echo "=== Done ==="
echo "Plugin: $INSTALL_DIR"
echo "Movies: $INSTALL_DIR/movies/ (.webm/.mp4)"
command -v ffmpeg >/dev/null 2>&1 && echo "ffmpeg: $(which ffmpeg) (thumbnails on)" || echo "ffmpeg: not found (optional)"
echo "Millennium: unmuted autoplay comes stock with recent Steam (no patch needed)"
echo ""
echo "Restart Steam to apply. Verify: grep startup-movies ~/.local/share/Steam/logs/millennium.log | tail -5"
