# Linux notes — what this side depends on, and what changed underneath it

The Linux path (FTP VFS) works and stays the reference implementation.
This note exists so future edits don't silently break it.

## Assumptions (all true today, none checked at runtime)
- VFS reads `std::ifstream(path)` in **text mode**
  (`Millennium/src/engine/http_hooks.cc:173`). Correct on Linux only
  because glibc text == binary. This is exactly what kills Windows.
- No video MIME rows (`Millennium/src/include/millennium/mime_types.h:30`).
  Video is served as `UNKNOWN` → `text/plain`, and Linux Chromium plays it
  anyway. If upstream ever adds real video MIME rows, nothing breaks —
  but don't "fix" our URLs in response.
- URL codec symmetry: `ftp_url_from_path` must byte-match
  `utils::url::encode_url` + `plat_encode_url`
  (`Millennium/src/include/millennium/url_parser.h:39`). Drift breaks
  every movie URL, surfacing only as a silent `onError → dismiss`.
- Layout: `movies/` next to the backend file, `movies/thumbs` writable.
- Frontend entry: Millennium loads `<plugin>/.millennium/Dist/index.js`
  (`Millennium/src/engine/plugin_manager.cc:173`) — never `frontend/`.
  The Dist output is committed and must be rebuilt on every `index.tsx`
  change; a fresh clone with a stale/missing `Dist/` runs old UI (or
  none) with no error. (`frontend/index.js` is a local build copy,
  gitignored.)

## What the Windows port changed on the shared side
- `fs.create_directories` instead of `mkdir -p` (works everywhere).
- `get_status` gained `data_serving` / `is_windows`. Panel only reads
  `has_ffmpeg`; safe to ignore the rest here.
- Movie list items on Windows carry `has_thumb` instead of `url`/`thumb`;
  Linux items are unchanged (`url` + `thumb` FTP URLs).
- `resolvePlayUrl` in the frontend: FTP URL if present, else on-demand
  `get_movie_data`. Linux always takes the first branch.
- Installers use the shipped prebuilt (skip-by-default, `--rebuild` to force).
  `install.ps1` is its Windows mirror — keep flags
  (`--dir`, `--rebuild`, `--release`, `--branch`) and layout guarantees
  (`movies/thumbs`) in lockstep.
- `package.json` `postbuild` is a node one-liner (no POSIX tools), so
  `npm run build` works on Windows too. Only the ttc compiler + node
  are required for `--rebuild`.

## Deliberately different (not tech debt)
- Linux streams via FTP (unbounded size, byte-ranges, tiny IPC).
  Windows embeds one file as a data URL (64MB cap, ~1.33× memory).
  Do not unify transports; the frontend abstraction is the unification.
- `ps aux` / `which` / `&` idioms stay in Linux branches.
