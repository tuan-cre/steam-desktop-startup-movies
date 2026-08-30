# Steam Desktop Startup Movies

A [Millennium](https://millennium.dev/) plugin that plays a custom startup movie on Steam desktop launch — just like the Steam Deck startup animation, but for your PC.

## Why This Plugin?

Steam only supports startup movies in Big Picture mode. This plugin brings that experience to the regular desktop Steam client. Drop in a video, restart Steam, and enjoy your custom intro every time.

## Installation

**One-liner (installs plugin + patches Millennium for stable FTP):**
```bash
curl -fsSL https://raw.githubusercontent.com/tuan-cre/steam-desktop-startup-movies/master/scripts/install.sh | bash
# — clones to ~/.local/share/millennium/plugins/startup-movies,
#   builds frontend if needed, then auto-patches Millennium
#   (--autoplay-policy) for no-freeze FTP on stock 3.4.1
# skip patch: | bash -s -- --no-patch
```

**Manual:**
```bash
git clone https://github.com/tuan-cre/steam-desktop-startup-movies ~/.local/share/millennium/plugins/startup-movies
cd ~/.local/share/millennium/plugins/startup-movies && npm install && npm run build
./scripts/patch-millennium.sh # or auto via install.sh
# add movies/*.webm then Restart Steam
```

Requires [Millennium](https://millennium.dev/) v3+ before install.

## Features

- **Automatic playback** — video plays on Steam startup, dismissible by clicking
- **Movie selector** — choose which movie to play from the config panel
- **Video fit modes** — Contain (letterbox), Cover (crop), or Fill (stretch)
- **Thumbnail previews** — auto-generated preview images in the config panel (requires ffmpeg)
- **Plugin-local videos** — movies are stored inside the plugin folder, not Steam's config directory
- **Configurable transition** — choose between smooth fade or instant cut
- **Shuffle mode** — randomly pick a different movie each startup
- **Zero-dependency serving** — movies served via Millennium's FTP VFS (`https://millennium.ftp`), no Python or extra HTTP server
- **Diagnostics** — status messages in the config panel when dependencies are missing

## Adding Movies

Drop any `.webm` or `.mp4` file into the `movies/` folder. The plugin will detect it automatically on next startup.

## Configuration

Open the plugin panel from Millennium's plugin settings:

- **Movie** — select which video to play at startup (shows file size and thumbnail)
- **Video Fit** — how the video scales to fill the screen (contain, cover, or fill)
- **Transition** — fade out or instant cut when dismissing the video
- **Playback Mode** — static (always plays the selected movie) or shuffle (random pick each startup)
- **Audio** — toggle sound on/off for startup movies (off by default)

## Requirements

- [Millennium](https://millennium.dev/) v3+
- ffmpeg (optional, for thumbnail generation)

No Python required — movies are served via Millennium's built-in FTP VFS. If ffmpeg is missing, the plugin will show a status message and thumbnails will be disabled.

## Audio & Millennium Compatibility

The plugin uses a **hybrid** strategy so it works on both stock and patched Millennium without freezing:

- **Stock Millennium** — video starts `muted` (allowed by CEF) then unmutes ~100ms after decode via `play().catch()` fallback. No freeze, slight delay before sound.
- **Patched Millennium** (`--autoplay-policy=no-user-gesture-required` in `src/instrumentation/internal/steam_hooks.cc:225`) — native unmuted `autoplay`, instant sound. The config panel shows `Compatibility: Patched Millennium detected` vs `Stock ... muted-first fallback`.

Only `1` line in Millennium is needed for instant audio; the prehide/black-overlay patches are now handled inside the plugin (`frontend/steam-hide.css:6`).

### Dev-only: patch Millennium for instant audio

End-users don't need this — hybrid already works. For devs who want the patch without keeping a permanent clone:

```bash
./scripts/patch-millennium.sh
# temp clones https://github.com/SteamClientHomebrew/Millennium to /tmp,
# inserts the autoplay flag, builds Release -m32, and sudo links to /usr/lib/millennium/
# Restart Steam after
```

Requires `cmake`, `ninja`, `gcc -m32` (`gcc-multilib` / `lib32`). If you already have `~/Projects/Millennium` cloned, just `grep -q autoplay-policy src/instrumentation/internal/steam_hooks.cc ||` apply the one-liner and `cmake --build build`.

## Troubleshooting

- **No movies appear** — Make sure `.webm` or `.mp4` files are in the `movies/` folder inside the plugin directory
- **Video doesn't play** — Check Millennium logs (`~/.local/share/Steam/logs/`) for `Startup Movies plugin loaded (dev/ftp VFS`); ensure movies are `.webm`/`.mp4`
- **Thumbnails missing** — Install ffmpeg for automatic thumbnail generation
- **No sound / delayed sound** — Stock Millennium delays unmute until after playback starts (hybrid fallback). Run `scripts/patch-millennium.sh` for instant audio, or leave as-is

## License

MIT
