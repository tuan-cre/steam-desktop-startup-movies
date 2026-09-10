#!/usr/bin/env bash
# One-liner installer for steam-desktop-startup-movies
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/tuan-cre/steam-desktop-startup-movies/master/install.sh | bash
#   bash install.sh [--dir <path>] [--rebuild] [--release <zip-url>]
set -euo pipefail

REPO="https://github.com/tuan-cre/steam-desktop-startup-movies.git"
BRANCH="master"
PLUGIN_NAME="startup-movies"

INSTALL_DIR=""
REBUILD=0
RELEASE_URL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir) INSTALL_DIR="$2"; shift 2 ;;
        --rebuild) REBUILD=1; shift ;;
        --release) RELEASE_URL="$2"; shift 2 ;;
        --branch) BRANCH="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: install.sh [--dir <path>] [--rebuild] [--release <zip-url>] [--branch <branch>]"
            echo "  --dir      Custom plugin dir (default: \$XDG_DATA_HOME/millennium/plugins/$PLUGIN_NAME)"
            echo "  --rebuild  Force npm rebuild (default: use shipped .millennium/Dist/index.js)"
            echo "  --release  Install from prebuilt zip (no git/node)"
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

if [[ ! -d "${XDG_DATA_HOME:-$HOME/.local/share}/millennium" && ! -d "${XDG_CONFIG_HOME:-$HOME/.config}/millennium" && ! -d "$HOME/.millennium" ]]; then
    echo "WARN: Millennium not found (~/.config/millennium). Install first: https://steambrew.app/"
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
    # The repo ships a working prebuilt (.millennium/Dist/index.js is tracked
    # in git). Never build on mtime heuristics: fresh clones get arbitrary
    # timestamps that falsely trip -nt checks. --rebuild forces a build.
    if [[ $REBUILD -eq 1 ]]; then
        if command -v npm >/dev/null 2>&1; then
            echo "Rebuilding frontend (npm run build) ..."
            (cd "$INSTALL_DIR" && npm install --silent 2>&1 | tail -5; npm run build 2>&1 | tail -20)
            echo "Build done: $(wc -c < "$INSTALL_DIR/.millennium/Dist/index.js") bytes"
        else
            echo "WARN: npm missing - cannot rebuild" >&2; exit 1
        fi
    elif [[ ! -f "$INSTALL_DIR/.millennium/Dist/index.js" ]]; then
        echo "WARN: .millennium/Dist/index.js missing - re-run with --rebuild (needs npm)" >&2
    else
        echo "Frontend prebuilt, skip build (use --rebuild to force)"
    fi
fi

# --- Enable the plugin (Millennium keeps enabledPlugins in config.json) ---
# Steam must be closed: Millennium rewrites this file on exit/shutdown,
# which would clobber an edit made while it runs.
if pgrep -x steam >/dev/null 2>&1; then
    echo "WARN: Steam is running - skipping auto-enable (close Steam and re-run, or enable manually in Millennium settings)."
else
    MILLENNIUM_CONFIG=""
    for cand in "${XDG_CONFIG_HOME:-$HOME/.config}/millennium/config.json" "${XDG_DATA_HOME:-$HOME/.local/share}/millennium/config.json" "${XDG_DATA_HOME:-$HOME/.local/share}/millennium/config/config.json" "$HOME/.millennium/config/config.json"; do
        if [[ -f "$cand" ]]; then MILLENNIUM_CONFIG="$cand"; break; fi
    done
    if [[ -z "$MILLENNIUM_CONFIG" ]]; then
        echo "WARN: Millennium config not found - enable the plugin manually in settings."
    elif command -v node >/dev/null 2>&1; then
        cp "$MILLENNIUM_CONFIG" "$MILLENNIUM_CONFIG.bak"
        node -e '
            const fs = require("fs");
            const [cfgPath, name] = process.argv.slice(1);
            const cfg = JSON.parse(fs.readFileSync(cfgPath, "utf8"));
            cfg.plugins = cfg.plugins || {};
            cfg.plugins.enabledPlugins = cfg.plugins.enabledPlugins || [];
            if (!cfg.plugins.enabledPlugins.includes(name)) {
                cfg.plugins.enabledPlugins.push(name);
                fs.writeFileSync(cfgPath, JSON.stringify(cfg, null, 2) + "\n");
                console.log(`Enabled plugin ${name} in Millennium config.`);
            } else {
                console.log(`Plugin ${name} already enabled.`);
            }
        ' "$MILLENNIUM_CONFIG" "$PLUGIN_NAME"
    elif command -v python3 >/dev/null 2>&1; then
        cp "$MILLENNIUM_CONFIG" "$MILLENNIUM_CONFIG.bak"
        python3 - "$MILLENNIUM_CONFIG" "$PLUGIN_NAME" <<'EOF'
import json, sys
path, name = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = json.load(f)
cfg.setdefault("plugins", {}).setdefault("enabledPlugins", [])
if name not in cfg["plugins"]["enabledPlugins"]:
    cfg["plugins"]["enabledPlugins"].append(name)
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    print(f"Enabled plugin {name} in Millennium config.")
else:
    print(f"Plugin {name} already enabled.")
EOF
    else
        echo "WARN: neither node nor python3 found - enable the plugin manually in Millennium settings."
    fi
fi

echo ""
echo "=== Done ==="
echo "Plugin: $INSTALL_DIR"
echo "Movies: $INSTALL_DIR/movies/ (video files)"
command -v ffmpeg >/dev/null 2>&1 && echo "ffmpeg: $(which ffmpeg) (thumbnails on)" || echo "ffmpeg: not found (optional)"
echo ""
echo "Restart Steam to apply."
