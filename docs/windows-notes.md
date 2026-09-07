# Windows support — revisit notes

Deleted branch: `windows-support` (was a mess, outdated vs master).
Full history still on origin until deleted; diary was `WINDOWS-SUPPORT.md` on that branch.

## Goal
Same plugin on Windows: play startup movie on Steam launch.

## Root cause found
Millennium's FTP VFS (`https://millennium.ftp`) can't serve video on Windows.
Its `vfs_request_handler` has no video MIME types, reads files in text mode,
and on Windows text reads stop at the first `0x1A` byte — which every WebM
starts with (EBML magic). Result: empty body, `MEDIA_ERR_SRC_NOT_SUPPORTED`,
black screen. Linux reads binary so it works there.

## Approach taken (unverified end-to-end)
Revive python http.server: serve `movies/` on `http://127.0.0.1:18080`,
validate python actually runs (reject the dead Store stub), launch
non-blocking, confirm the port listens, kill on unload. See the deleted
branch's `backend/main.lua` + `scripts/install.ps1` if needed.

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
