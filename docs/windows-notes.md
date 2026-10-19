# Windows notes

Same plugin, same goal as Linux (play a startup movie on launch), but Windows
can't use the Linux FTP path, so it serves movies a different way.

Source paths below are relative to the Millennium repo root.

## Serving model
- **Linux:** FTP virtual filesystem (`https://millennium.ftp`), no size limit.
- **Windows:** movies are embedded as base64 data URLs — no server, no Python,
  no port, no spawned process. One movie is ever embedded at a time, so peak
  memory is ~1.33× the file. `DATA_MAX_BYTES` (64 MB) caps it, enforced on both
  ends: `get_movie_chunk` clamps to the ceiling, and the frontend aborts the
  chunk loop if the running total exceeds it (covers an unknown `size`).

## Why FTP can't serve video on Windows
- The VFS opens files with a plain `std::ifstream` (`src/engine/http_hooks.cc`)
  — text mode. On Windows text reads stop at the first `0x1A` byte, which every
  WebM starts with (EBML magic). The body comes back empty, so Chromium raises
  `MEDIA_ERR_SRC_NOT_SUPPORTED` and the overlay dismisses after a black flash.
  Linux reads the same code path, but there text == binary, so it works.
- `src/include/millennium/mime_types.h` has no video rows (CSS/JS/fonts/images/
  HTML only), so video falls through to `UNKNOWN` → `Content-Type: text/plain`
  and the text-read branch.
- The URL layer is fine on Windows (`plat_encode_url` / `get_path_from_url` in
  `src/include/millennium/url_parser.h` handle `C:\…` paths), so the upstream
  fix would be small (binary mode + video MIME rows). That's out of scope here,
  so we work around it.

An A/B test in a real client confirmed it: the same file plays over
`http://127.0.0.1:18080/…`, but gives a 0.1s black flash then an instant dismiss
over the FTP URL, repeatably — matching the text-mode / `text/plain` diagnosis.

## Processes
ffmpeg is the only process the plugin ever spawns, and only to create a missing
thumbnail:
- Spawns are debounced per thumbnail (`THUMB_RETRY_SECONDS` in
  `backend/main.lua`), so `get_movies` rescans don't stack jobs.
- Finding ffmpeg is subprocess-free on Windows: `find_ffmpeg` scans `PATH` and
  the common install dirs with `fs.exists`, instead of `where` (which flashed a
  console on every Steam launch). Linux still uses `which` — no console there.
- Residual: the ffmpeg thumbnail job itself still shells out once per new movie
  (`start /B`), so that single flash can appear while a thumbnail is missing.
  Making it flash-free needs a non-blocking, no-window spawn; `utils.exec` is
  `CREATE_NO_WINDOW` but blocking, so it would stall the startup scan.

## Detour worth remembering
An early version served `movies/` over a local `pythonw -m http.server`. It
worked end-to-end, but every `io.popen` / `os.execute` flashes a console at
Steam launch, and combining launch + validate into one console exposed a
pipe-inheritance hang (`read()` blocks until the detached child exits).
Embedded data URLs do the same with zero processes, so the server was removed.
Lessons kept: `fs.exists` pre-filters before any probe, use `utils.base64_encode`
over shell-outs, and `pcall` the startup path.

## Layout
- Install path: `C:\Program Files (x86)\Steam\millennium\plugins\startup-movies`
  (not `%LOCALAPPDATA%\millennium\…`).
- No Python needed; ffmpeg optional (thumbnails). Installer: `install.ps1`.
