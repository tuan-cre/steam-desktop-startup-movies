# Steam Desktop Startup Movies

Millennium plugin that plays a startup movie on Steam launch, like Steam Deck.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/tuan-cre/steam-desktop-startup-movies/master/scripts/install.sh | bash
```

Or manual: clone to `~/.local/share/millennium/plugins/startup-movies`, `npm install && npm run build`.

Requires Millennium v3+.

## Movies

Drop video files into the plugin's `movies/` folder and restart Steam.

Supported: `.webm` `.mp4` `.m4v` `.mov` `.mkv` `.ogv` `.ogg` — whatever Chromium decodes. Unplayable files are skipped.

## Config

Millennium → Settings → Plugins → **Startup Movies**: pick movie, fit, transition, shuffle, audio. Preview plays the selection immediately.

Requires Steam → Settings → Interface → Startup Location → **Library**, or the Store renders over the movie.

## Troubleshoot

- No movies — check `movies/` folder, hit Refresh
- No thumbnail — install ffmpeg
- No sound — enable Audio

MIT
