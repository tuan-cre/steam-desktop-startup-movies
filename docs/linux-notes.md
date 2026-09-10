# Linux notes — assumptions & cleanup ideas (from the Windows port)

The Linux path is the stable reference. This note records what it silently
depends on, and what the Windows port taught us that applies back.

## Load-bearing assumptions (all currently true, none checked at runtime)
- FTP VFS reads `std::ifstream(path)` in **text mode**
  (`Millennium/src/engine/http_hooks.cc:173`). Works on Linux only because
  glibc text == binary for bytes. Breaks on Windows at the first `0x1A`.
- No video MIME rows exist (`Millennium/src/include/millennium/mime_types.h:30`
  — CSS/JS/fonts/images/HTML only). Video falls through to `UNKNOWN` →
  `Content-Type: text/plain` + the text-read branch. Linux Chromium plays it
  anyway; Windows returns an empty body.
- URL codec symmetry: backend `ftp_url_from_path` must match
  `utils::url::encode_url` + `plat_encode_url`
  (`Millennium/src/include/millennium/url_parser.h:39`) exactly —
  space → `+`, unreserved set `-_.~/` verbatim, rest `%XX`. Any drift breaks
  every movie URL with zero error at scan time (failure surfaces only as
  `onError → dismiss` in the overlay).
- `MILLENNIUM_PLUGIN_SECRET_BACKEND_ABSOLUTE` + `fs.parent_path/join` locate
  `movies/`. No fallback if the layout ever changes.

## Cleanup ideas (behavior-preserving)
1. **Split a `platform.lua`** (`linux.lua` / `windows.lua`): URL builder,
   python finder, server start/stop, process probes. `main.lua` keeps only
   shared flow. The Windows branch grew by inline `if IS_WINDOWS` — don't
   repeat the pattern on this side.
2. **`pcall` the `on_load` sequence.** Proven this session: an unguarded
   startup step can die with zero log lines. One `pcall` + `logger:error`
   around load would have saved an hour.
3. **No shell-outs where a builtin exists**: `fs.create_directories`
   replaced `mkdir -p` (done, shared); the `http` Lua module replaced port
   probes. Audit remaining `io.popen`/`os.execute` (`which ffmpeg`,
   `ps aux | grep`, thumbnail `&` backgrounding) for builtin alternatives.
4. **Cross-platform `postbuild`**: `package.json` uses POSIX `cp -r`
   (breaks `npm run build` on Windows cmd). Replace with a node one-liner
   or ttc output config so both sides build the same way.
5. **Symmetric `get_status`**: Windows reports `is_windows`/`has_python`/
   `http_port`; add Linux equivalents (`ftp_serving` diagnostics) so the
   settings panel can reason about both stacks.
6. **Keep `install.sh` / `install.ps1` in lockstep** — same flags
   (`--dir`, `--no-build`, `--release`, `--branch`), same layout guarantees
   (`movies/thumbs`, `.keep`).

## Deliberately Linux-only (do not "fix" for parity)
- FTP VFS serving (no local server, no port, no python dependency).
- `which` / `ps aux` / `&` / `/dev/null` idioms in the Linux branches.
