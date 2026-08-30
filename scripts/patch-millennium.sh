#!/usr/bin/env bash
# Dev-only: temp-clone Millennium, apply audio autoplay patch, rebuild and deploy.
# Hybrid plugin already works on stock Millennium (muted-first fallback, no freeze).
# This gives patched Millennium = instant unmuted autoplay (no 100ms muted delay).
set -euo pipefail

REPO="https://github.com/SteamClientHomebrew/Millennium.git"
TMPDIR="$(mktemp -d /tmp/millennium-patch-XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "=== Temp clone Millennium to $TMPDIR ==="
git clone --depth 1 "$REPO" "$TMPDIR"

FILE="$TMPDIR/src/instrumentation/internal/steam_hooks.cc"
if grep -q 'autoplay-policy' "$FILE"; then
    echo "Already patched (autoplay-policy present), skipping patch."
else
    echo "Patching $FILE ..."
    # Insert after the disable-blink line; preserve indentation
    if grep -q 'disable-blink-features' "$FILE"; then
        # Use awk to insert after that line to avoid sed escaping issues
        awk '
            /disable-blink-features/ {print; print "    cmd_line.ensure_param(\"--autoplay-policy\", \"no-user-gesture-required\");"; next}1
        ' "$FILE" > "$FILE.tmp" && mv "$FILE.tmp" "$FILE"
    else
        echo "WARN: disable-blink-features not found, appending patch manually"
        echo '    cmd_line.ensure_param("--autoplay-policy", "no-user-gesture-required");' >> "$FILE"
    fi
    grep -q 'autoplay-policy' "$FILE" || { echo "Patch failed"; exit 1; }
    echo "Patched."
fi

echo "=== Checking build deps ==="
for dep in cmake ninja git gcc; do
    command -v "$dep" >/dev/null 2>&1 || { echo "Missing $dep. Install base-devel."; exit 1; }
done
# Check -m32 support
if ! gcc -m32 -dM -E - </dev/null >/dev/null 2>&1; then
    echo "gcc -m32 not working. Install gcc-multilib / lib32-* (Arch: sudo pacman -S gcc-multilib)"
    exit 1
fi

echo "=== Building Millennium (Release, -m32) ==="
# Use preset if available, else plain cmake
if [[ -f "$TMPDIR/CMakePresets.json" ]]; then
    cmake --preset linux-release -S "$TMPDIR" -B "$TMPDIR/build" 2>/dev/null || \
        cmake -B "$TMPDIR/build" -S "$TMPDIR" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS="-m32" -DCMAKE_C_FLAGS="-m32"
else
    cmake -B "$TMPDIR/build" -S "$TMPDIR" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS="-m32" -DCMAKE_C_FLAGS="-m32"
fi
cmake --build "$TMPDIR/build" -j"$(nproc)"

echo "=== Deploying to /usr/lib/millennium (needs sudo) ==="
for lib in libmillennium_x86.so libmillennium_hhx64.so libmillennium_bootstrap_x86.so libmillennium_bootstrap_hhx64.so; do
    src="$TMPDIR/build/$lib"
    dst="/usr/lib/millennium/$lib"
    [[ -f "$src" ]] || { echo "Missing $src, skipping"; continue; }
    if [[ -f "$dst" && ! -L "$dst" ]]; then
        sudo mv "$dst" "$dst.bak" && echo "Backed up $dst -> $dst.bak"
    fi
    sudo ln -sf "$src" "$dst" && echo "Linked $dst -> $src"
done

if grep -q 'autoplay-policy' /proc/cmdline 2>/dev/null; then
    echo "Note: current steamwebhelper cmdline check not reliable (checks parent). Restart Steam to apply."
fi
echo "Done. Restart Steam - patched Millennium will show 'Patched Millennium detected' in plugin Compatibility panel."
echo "Hybrid fallback remains for stock users; no action needed otherwise."
