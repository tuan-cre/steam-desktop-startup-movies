# Linux notes

Linux serves movies through Millennium's FTP virtual filesystem
(`https://millennium.ftp`) and is the reference implementation. Playback rests
on a few upstream behaviours that aren't checked at runtime, so a change in
Millennium can break it silently (`onError` → dismiss with no error shown).
They're recorded here so edits don't regress it.

Source paths below are relative to the Millennium repo root.

## Upstream assumptions
- **VFS reads files in text mode.** `src/engine/http_hooks.cc` opens the file
  with a plain `std::ifstream` (no `ios::binary`). Harmless on Linux, where text
  and binary reads are identical — but it's exactly what breaks Windows (see
  `windows-notes.md`).
- **No video MIME types.** `src/include/millennium/mime_types.h` maps only
  CSS/JS/JSON/fonts/images/HTML. Video resolves to `UNKNOWN` →
  `Content-Type: text/plain` and takes the text-read branch. Linux Chromium
  plays it anyway; if upstream ever adds real video MIME rows, nothing breaks —
  but don't "fix" our URLs in response.
- **URL codec symmetry.** `ftp_url_from_path` must byte-match Millennium's
  `utils::url::encode_url` + `plat_encode_url` (`src/include/millennium/url_parser.h`):
  alnum and `- _ . ~ /` verbatim, space → `+`, everything else `%XX` uppercase,
  with Linux dropping the leading `/`. Drift breaks every movie URL and shows up
  only as a silent dismiss.
- **Frontend entry point.** Millennium loads `<plugin>/.millennium/Dist/index.js`
  (`src/engine/plugin_manager.cc`), never `frontend/`. The bundle is committed
  and must be rebuilt (`npm run build`) on every `frontend/index.tsx` change — a
  stale or missing `Dist/` runs old UI, or nothing, with no error.
  (`frontend/index.js` is only a local build copy, gitignored.)
- **Layout.** `movies/` sits next to the backend file; `movies/thumbs` must be
  writable.

## What the Windows port changed on the shared side
- `fs.create_directories` instead of shelling out to `mkdir -p`.
- `get_status` gained `data_serving` / `is_windows`; the panel only reads
  `has_ffmpeg`, so the rest is informational.
- Movie list items differ by platform: Linux carries `url` + `thumb` (FTP URLs);
  Windows carries `has_thumb` and resolves bytes on demand.
- `resolvePlayUrl` returns the FTP URL when present, otherwise fetches via
  `get_movie_data` / `get_movie_chunk`. Linux always takes the first branch.
- Installers ship the prebuilt bundle by default (`--rebuild` forces a build).
  `install.ps1` mirrors `install.sh` — keep the flags (`--dir`, `--rebuild`,
  `--release`, `--branch`) and the `movies/thumbs` guarantee in lockstep.
- `package.json`'s `postbuild` is a node one-liner (no POSIX tools), so
  `npm run build` works on Windows too.

## Deliberately different (not debt)
- Linux streams over FTP (no size limit, byte ranges, tiny IPC). Windows embeds
  one file as a data URL (64 MB cap, ~1.33× memory). Don't unify the transports;
  the frontend abstraction is the unification.
- `which` / `&` idioms stay in the Linux branches.
