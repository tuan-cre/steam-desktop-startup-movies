# dev: ftp file serving (replace python http.server) — implemented

Goal: drop `python3 -m http.server` `backend/main.lua:182` and serve `movies/` via Millennium's existing `https://millennium.ftp/<absolute_path>` (`src/engine/http_hooks.cc:138` `vfs_request_handler`).

## Why
- No extra process/port race (`base_port 18080` +6 tries)
- No `python3` dep, no `kill -0` polling
- One ftp VFS already serves `frontend/index.js` via `https://millennium.ftp/<path>` (`src/include/millennium/url_parser.h:79`)

## Implemented (dev branch 2026-08-30)
1. **Backend** `backend/main.lua`:
   - Removed `find_python`, `server_pid/url`, `start_http_server` (~70 lines).
   - Added `FTP_BASE = "https://millennium.ftp"` + `ftp_url_from_path()` mirroring `utils::url::encode_url` — `https://millennium.ftp/<encoded_abs_path>`.
   - `get_movies()` now returns `url = ftp_url_from_path(abs_path)` for each `.webm/.mp4`, `thumb = ftp_url_from_path(thumb_path)`.
   - `on_load()` no longer starts server, logs `served via https://millennium.ftp`, `on_unload()` no `kill`.
   - `get_status()` returns `has_python=true, server_running=true, ftp_serving=true` for frontend compat.
2. **Frontend** `frontend/index.tsx`:
   - No URL construction change needed (backend provides ftp URL).
   - `Panel` suppresses python/server warnings when `ftp_serving`, appends `| FTP VFS serving (no python)` to `hybridInfo`.
   - Keeps hybrid `muted` fallback `index.tsx:121`, `steam-hide.css:6` override.
3. **Thumbs**: same ftp path, still `ffmpeg` background gen.
4. **Tests**: `npm run build` prod `3.10s` ok, `frontend/index.js` contains `ftp_serving`.

## Known caveat
`http_hooks.cc:198` `Fetch.fulfillRequest` serves full file (no `Range`/`Accept-Ranges`). Startup movie plays from start fine; seeking during playback may not work. For large files, consider adding range support or `blob:` fallback.

## Branches
- `master` = hybrid python server (stable, `441d4b7`)
- `dev` = ftp VFS (this branch, no python)
