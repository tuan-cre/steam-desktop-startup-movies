# Steam Desktop Startup Movies

A [Millennium](https://millennium.dev/) plugin that plays a custom startup movie on Steam launch — like Steam Deck, but for desktop.

## Installation

**One-liner (installs plugin + patches Millennium for stable playback):**
```bash
curl -fsSL https://raw.githubusercontent.com/tuan-cre/steam-desktop-startup-movies/master/scripts/install.sh | bash
```
Then add `.webm`/`.mp4` to `movies/` and restart Steam.

```bash
# skip patch (stock 3.4.1 may freeze every-other with FTP)
curl -fsSL .../install.sh | bash -s -- --no-patch
```

**Manual:**
```bash
git clone https://github.com/tuan-cre/steam-desktop-startup-movies ~/.local/share/millennium/plugins/startup-movies
cd ~/.local/share/millennium/plugins/startup-movies && npm install && npm run build
./scripts/patch-millennium.sh
```

Requires Millennium v3+.

## Features

- Plays on startup, click to dismiss
- Movie picker with thumbnails (needs ffmpeg)
- Fit: Contain / Cover / Fill · Transition: Fade / Cut
- Shuffle, Audio toggle

## Configuration

Millennium → Settings → Plugins → **Startup Movies**

- **Movie** — pick video (shows size and thumbnail)
- **Playback** — Video Fit, Transition, Shuffle, Audio

Header shows movie count and patched/stock status.

## Adding Movies

Drop `.webm` or `.mp4` files into the plugin's `movies/` folder and restart Steam.

## Requirements

- Millennium v3+
- ffmpeg (optional, for thumbnails)

No Python needed — movies via `https://millennium.ftp` VFS.

## Audio

- **Stock** — muted-first hybrid (small delay, no freeze)
- **Patched** — instant sound (`--autoplay-policy=no-user-gesture-required`)

The one-liner patches automatically; manual: `./scripts/patch-millennium.sh` (needs `cmake` `gcc -m32`).

## Troubleshooting

- **No movies** — check `movies/` folder
- **No thumbnail** — install ffmpeg
- **Freeze every-other** — stock FTP needs patch; re-run installer without `--no-patch`
- **No sound** — enable Audio; patch for instant audio

## License

MIT
