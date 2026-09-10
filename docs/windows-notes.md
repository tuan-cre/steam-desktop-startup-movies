# Windows support — revisit notes

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

## Approach (in progress on master)
Revive python http.server: serve `movies/` on `http://127.0.0.1:18080`,
validate python actually runs (reject the dead Store stub), launch
non-blocking via `start /B`, confirm the port listens (TcpClient probe),
kill only the PID bound to 18080 on unload. Implemented in
`backend/main.lua` (`IS_WINDOWS` branch); installer is `install.ps1`.
Linux path (FTP VFS) untouched.

## Facts that may have shifted
- Master is now v1.1.1: source-of-truth is `frontend/index.tsx` (starlight
  compiles it at load), multi-format support, no Startup Location detection,
  no Millennium patch needed (Steam ships `--autoplay-policy` stock).
- Any Windows retry must rebuild on current master, not on the old branch code.
- Correct Windows install path was
  `C:\Program Files (x86)\Steam\millennium\plugins\startup-movies`
  (not `%LOCALAPPDATA%\millennium\...`).
- Open item when parked: confirm the python server actually binds a port on
  Windows, then strip the `DBG` logging.
