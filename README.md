# Steam Desktop Startup Movies

A [Millennium](https://millennium.dev/) plugin that plays a custom startup movie on Steam launch — like Steam Deck, but for desktop.

## Installation

**Linux — one-liner (installs plugin + patches Millennium for stable playback):**
```bash
curl -fsSL https://raw.githubusercontent.com/tuan-cre/steam-desktop-startup-movies/master/scripts/install.sh | bash
```
Then add `.webm`/`.mp4` to `movies/` and restart Steam.

```bash
# skip patch (stock 3.4.1 may freeze every-other with FTP)
curl -fsSL .../install.sh | bash -s -- --no-patch
```

**Windows — PowerShell (run as Administrator):**
```powershell
irm https://raw.githubusercontent.com/tuan-cre/steam-desktop-startup-movies/windows-support/scripts/install.ps1 | iex
```
Then add `.webm`/`.mp4` to `C:\Program Files (x86)\Steam\millennium\plugins\startup-movies\movies\` and restart Steam.

> **Windows note:** the plugin serves movies through a small local Python HTTP server
> (not Millennium's FTP VFS, which can't serve video on Windows), so it needs **Python 3**
> installed and on PATH (`python`/`python3`). On stock Millennium it runs using the
> muted-first hybrid audio fallback (works out of the box). The optional Linux-only
> Millennium patch that enables *instant* unmuted audio does not yet exist for Windows.
> The plugin ships with a prebuilt frontend, so **no Node.js/npm is required**.

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
- **Python 3** (required — serves movies via a local HTTP server)
- ffmpeg (optional, for thumbnails)
- Steam → Settings → Interface → **Startup Location** must be set to **Library** (required for the movie to cover the UI on launch)

## Audio

- **Stock** — muted-first hybrid (small delay, no freeze)
- **Patched** — instant sound (`--autoplay-policy=no-user-gesture-required`)

The one-liner patches automatically; manual: `./scripts/patch-millennium.sh` (needs `cmake` `gcc -m32`). The autoplay patch is **Linux-only** — Windows always uses the stock muted-first hybrid.

> Windows note: Startup Location auto-detection reads `config.vdf` from
> `%APPDATA%\Steam\config\` / `%LOCALAPPDATA%\Steam\config\`. If it can't find it, the
> plugin falls back to a manual-verify notice — just set Startup Location to **Library**
> in Steam settings.

## Troubleshooting

- **No movies** — check `movies/` folder
- **Movie not showing / UI visible behind movie** — ensure Steam → Settings → Interface → Startup Location is set to **Library**, then restart Steam
- **No thumbnail** — install ffmpeg
- **Freeze every-other** — stock patch needed; re-run installer without `--no-patch`
- **Black screen / no movie** — ensure Python 3 is on PATH (movie HTTP server must start); check the log for `Movie HTTP server on port`
- **No sound** — enable Audio; patch for instant audio

## License

MIT
