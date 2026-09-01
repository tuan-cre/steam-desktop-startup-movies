# Windows Support — Status & Troubleshooting (`windows-support` branch)

## Goal
Get Steam Startup Movies playing a startup movie on Windows. The plugin is fully
functional on Linux (newest FTP version). On Windows the movie shows a **black
screen**. This document tracks the investigation, the root cause found, the fixes
applied, and what to check next on the Windows machine.

## Branch / commits
Branch: `windows-support` (pushed to `origin`). Key commits:

| Commit | Change |
| --- | --- |
| `8b38f15` | Correct plugin load path + ship prebuilt `frontend/index.js` (no npm needed) |
| `7605c2f` | Ship prebuilt `.millennium/Dist/index.js` (Millennium loads frontend from here) |
| `f71c199` | Add `DBG` diagnostics: log video element state/errors through backend |
| `f144947` | Percent-encode spaces in FTP url (spaces were raw → CEF fetch failed) |
| `894c9a0` | **Serve movies via python http.server** (FTP VFS can't serve video on Windows) |
| `8948ae4` | Fix `on_load` ordering so the HTTP server actually starts (movies dir init race) |
| `1fffb06` | Validate python actually runs + confirm server via `netstat` |
| `d559e53` | Non-blocking Windows launch (`os.execute` + stdio redirect, not `io.popen`) |

## Current install locations (Windows)
- Plugin install (where Millennium actually loads it):
  `C:\Program Files (x86)\Steam\millennium\plugins\startup-movies`
  (NOT the `%LOCALAPPDATA%\millennium\plugins\...` path — remove that stale copy if present)
- Movies drop folder: `C:\Program Files (x86)\Steam\millennium\plugins\startup-movies\movies`
- Environment on the user's machine: **no Node/npm**; python3 IS present (detected
  at `C:\Users\neon\AppData\Local\Microsoft\WindowsApps\python.exe`, verified `Python 3.12.10`).
- ffmpeg at `C:\Users\neon\AppData\Local\Microsoft\WinGet\Links\ffmpeg.exe`

## Root cause of the black screen
**Millennium's FTP VFS cannot serve video on Windows.**
- Millennium's `vfs_request_handler` (`src/engine/http_hooks.cc`) classifies file
  types via `mime_types.h`, which has **no `.webm`/`.mp4`/video types** at all.
- For non-binary file types (`UNKNOWN` → `is_bin_file` returns `false`) it reads the
  file with a **text-mode** `std::ifstream` (`istreambuf_iterator<char>`).
- On **Windows, text-mode file reads stop at the first `0x1A` (Ctrl-Z / EOF) byte.**
  Every WebM file starts with `0x1A 45 DF A3` (the EBML magic), so the body served is
  **empty** (or truncated), with `Content-Type: text/plain`.
- The `<video>` element therefore gets no usable media → `MEDIA_ERR_SRC_NOT_SUPPORTED`
  (`code=4`) → **black screen**.
- On **Linux**, `std::ifstream` defaults to **binary**, so the whole file is read and
  plays fine — which is why it works on Linux with identical code.

Switching to `.mp4` does **not** help: `.mp4` is also `UNKNOWN` in the MIME table and
hits the same text-mode read.

## The chosen fix (current branch state)
Revive the proven **python http.server** approach (the pre-FTP method in the git
history): serve movies from a real local HTTP server that returns correct `video/webm`
content-type, the full binary body, and byte-range support.

- `backend/main.lua`:
  - `find_python()` — discovers python (`where python`/`python3`/`py` on Windows) and
    **validates it actually runs** (`--version` prints `Python`) to reject the dead
    Microsoft Store `WindowsApps\python.exe` stub.
  - `start_http_server()` — serves `movies/` on `http://127.0.0.1:18080` (port auto-slots
    up to +6) with `--bind 127.0.0.1 --directory <movies>`.
  - Windows launch is **non-blocking**: `os.execute('powershell Start-Process ... 
    -RedirectStandardOutput/-RedirectStandardError')` so the detached server can't hold a
    shell pipe and hang the Lua backend. The server is confirmed by checking the port is
    actually **listening** (`netstat`), and the PID is read from `netstat`.
  - `on_load` order: `get_movies()` → `start_http_server()` → reset cache → `get_movies()`
    (so movie URLs use the HTTP server).
  - `on_unload` / `stop_http_server()` kills the process on the bound port.
  - `get_status()` now reports `http_serving` / `has_python` / `server_running`.
- `frontend/index.tsx` — settings panel now shows HTTP-server status instead of FTP VFS;
  `DBG` diagnostics log video element state through the backend for troubleshooting.
- Prebuilt bundles shipped: both `frontend/index.js` and `.millennium/Dist/index.js` are
  identical and committed (no Node needed on Windows).

**Requirement re-added: Python 3 must be on PATH for the Steam/steamwebhelper process.**

## Diagnostic evidence so far (from user logs)
1. Black screen, FTP URL with raw spaces → fixed in `f144947` (encode spaces as `+`).
2. STILL `code=4`, URL now correct, but `served via none` → server never started (the
   `on_load` ordering bug) → fixed in `8948ae4`.
3. After that: `Found python: ...WindowsApps\python.exe` but **no lines after**
   "Found python" → Lua backend hung inside `start_http_server` → non-blocking launch
   fix in `d559e53` (most recent).

## What to do on the Windows machine (next run)
1. Update the installed plugin to the latest commit:
   ```powershell
   Set-Location "C:\Program Files (x86)\Steam\millennium\plugins\startup-movies"
   git pull origin windows-support
   ```
   (or re-run `irm https://raw.githubusercontent.com/tuan-cre/steam-desktop-startup-movies/windows-support/scripts/install.ps1 | iex`).
2. **Fully quit Steam** (taskbar → Exit, or `taskkill /F /IM steam.exe` if stuck) and relaunch.
3. Check the startup-movies log for these lines in order:
   - `Found python: ... (Python 3.12.10)` → python OK
   - `Movie HTTP server on port 18080 (pid=...)` → server bound (this was the previously-missing line)
   - `Found 1 movie files (served via http://127.0.0.1:18080)`
   - `DBG chosen-movie ... url=http://127.0.0.1:18080/blue-archive.webm`
   - `DBG ... playing ... w=1280x720` (nonzero w/h = actually decoding = success)

## If it still fails, report back these exact things
- Paste the **full** startup-movies log lines **after** `Found python:` (is there a
  `Movie HTTP server on port...`, a warning, or nothing?)
- Run these in PowerShell on the Windows box and paste output:
  ```powershell
  py -3 --version
  where python
  where py
  netstat -ano | findstr :18080
  ```
- Confirm the stale install was removed:
  ```powershell
  Test-Path "C:\Users\neon\AppData\Local\millennium\plugins\startup-movies"; Test-Path "C:\Program Files (x86)\Steam\millennium\plugins\startup-movies\backend\main.lua"
  ```

## Not yet resolved / notes
- The python server must actually bind a port on Windows — this is the current open item
  (`d559e53` just shipped the non-blocking fix; it has NOT yet been confirmed on Windows).
- Thumbnails on Windows: second-run only (ffmpeg async). Separate from the black-screen
  issue. The `Start-Process` ffmpeg thumbnail command uses `-ArgumentList` which may break
  with spaces in paths — lower priority.
- Startup Location `config.vdf` detection still returns "not found" on the user's machine —
  that's a secondary warning (auto-detection reads `%APPDATA%\Steam\config` /
  `%LOCALAPPDATA%\Steam\config`); the movie can still play, just set Startup Location to
  Library in Steam settings for full coverage.
- Once playback is confirmed working on Windows, strip the `DBG` diagnostic logging for a
  clean final version, and consider pushing `master`'s `58e1b42` (Startup Location feature).
