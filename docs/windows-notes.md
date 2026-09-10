# Windows support — notes

## Serving model (final)
- Linux: FTP VFS (`https://millennium.ftp`). Unchanged.
- Windows: embedded base64 data URLs (no server, no python, no port).
  One movie is ever embedded at a time; files over 64MB are refused
  (`DATA_MAX_BYTES` in `backend/main.lua`).

## History
Deleted branch: `windows-support` (was a mess, outdated vs master).
Full history still on origin until deleted; diary was `WINDOWS-SUPPORT.md` on that branch.

## Goal
Same plugin on Windows: play startup movie on Steam launch.

## Root cause found (verified in Millennium source, Sep 2026)
Millennium's FTP VFS (`https://millennium.ftp`) can't serve video on Windows:
- `src/engine/http_hooks.cc:173` opens files with `std::ifstream(path)` —
  text mode. On Windows text reads stop at the first `0x1A` byte, which every
  WebM starts with (EBML magic). Result: empty body,
  `MEDIA_ERR_SRC_NOT_SUPPORTED`, black screen. Linux reads the same code path
  but its text==binary for bytes, so it works there.
- `src/include/millennium/mime_types.h:30` has no video types at all
  (CSS/JS/fonts/images/HTML only). Video falls through to `UNKNOWN` ->
  `Content-Type: text/plain` and the text-read branch (`is_bin_file` false).
- URL layer is fine on Windows (`plat_encode_url` / `get_path_from_url` in
  `src/include/millennium/url_parser.h` handle `C:\...` paths), so a C++ fix
  would be small (binary mode + video MIME rows) but is out of scope for this
  plugin — we work around it below.

## Verdict: FTP confirmed dead on Windows (tested Sep 2026)
A/B experiment in the real client, same file (`blue-archive.webm`):
- `http://127.0.0.1:18080/blue-archive.webm` → plays, audio works.
- `https://millennium.ftp/c%3A/program%20files%20%28x86%29/.../blue-archive.webm`
  → 0.1s black flash then instant dismiss (`onError`), repeatable.
Matches the code diagnosis exactly (text-mode read → empty body +
`text/plain` MIME → `MEDIA_ERR_SRC_NOT_SUPPORTED`).

## Detour: local http.server (tried, then removed)
An intermediate port served `movies/` over `http://127.0.0.1:18080` via
`pythonw -m http.server` (Store-stub rejection, single-console launch,
spawn-free polling). It worked end-to-end (video + audio + thumbs), but every
`io.popen`/`os.execute` flashes a console at Steam launch, and combining
launch+validate into one console exposed a pipe-inheritance hang
(`read()` blocks until the detached child exits — forever). Embedded data
URLs achieve the same with zero processes, so the server was deleted.
Lessons kept: `fs.exists` pre-filters before any probe, `utils.base64_encode`
/ `http` builtins over shell-outs, `pcall` the startup path.

## Facts that may have shifted
- Master is now v1.2.0: source-of-truth is `frontend/index.tsx` (ttc
  compiles it to `.millennium/Dist/index.js` at build; both the Dist
  output and the `frontend/` copy are committed so installs need no
  build), multi-format support, no Startup Location detection,
  no Millennium patch needed (Steam ships `--autoplay-policy` stock).
- Correct Windows install path is
  `C:\Program Files (x86)\Steam\millennium\plugins\startup-movies`
  (not `%LOCALAPPDATA%\millennium\...`). No python needed; ffmpeg optional
  (thumbnails). Installer: `install.ps1`.
