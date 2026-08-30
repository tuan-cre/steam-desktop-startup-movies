# dev: ftp file serving (replace python http.server)

Goal: drop `python3 -m http.server` `backend/main.lua:182` and serve `movies/` via Millennium's existing `https://millennium.ftp/<token>/` (`src/instrumentation/loopback/main.cc:313`, `src/engine/plugin_loader.cc:275` `get_ftp_url()`).

## Why
- No extra process/port race (`base_port 18080` +6 tries)
- No `python3` dep, no `kill -0` polling, no `cached_movies` stale json
- One ftp server already serves `frontend/index.js`

## Plan (dev branch)
1. **Backend** `backend/main.lua`:
   - Remove `start_http_server`, `server_pid/url`, `find_python`, `ps autoplay` stays for compat.
   - `ensure_movies_dir()` returns absolute `movies_path` (keep `thumbs/`).
   - `get_movies()` returns `name/size` + `abs_path` (not `url`). Frontend resolves via `get_ftp_url` or new `get_movie_url(name)` that returns `https://millennium.ftp/<token>/startup-movies/movies/<file>` via `network_hook_ctl` hook.
   - Add `millennium.add_browser_hook` equivalent via `network_hook_ctl::TagTypes` if needed, or expose `get_ftp_token` via new ` Millenium.ftp_url` IPC.
2. **Frontend** `frontend/index.tsx`:
   - `loadMovies()` builds `url = await callBackend("get_movie_url", {name})` or `https://millennium.ftp/...`.
   - Keep hybrid `muted` fallback `index.tsx:121`, `steam-hide.css:6` override.
3. **Thumbs**: serve similarly via ftp, or `fs.read` + `data:image/jpeg;base64` from backend.
4. **Config**: migrate `localStorage` `OBJECT_FIT/TRANSITION/MODE/AUDIO` to `plugin_config` (`CONFIG_GET/SET` `main.lua:961`) for cross-restart sync.

## Test
- Stock Millennium: `muted` then unmute after `onLoadedData` still works.
- Patched: instant audio.
- No python installed: `get_status` no longer reports `has_python`.

## Branches
- `master` = hybrid python server (stable)
- `dev` = this ftp refactor (WIP)
