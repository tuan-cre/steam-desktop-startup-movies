local millennium = require("millennium")
local fs = require("fs")
local logger = require("logger")

local IS_WINDOWS = package.config:sub(1, 1) == "\\"

local movies_path = nil
local thumbs_path = nil
local cached_movies = nil
local cached_count = 0
local ffmpeg_bin = nil

-- Millennium ftp VFS: https://millennium.ftp/<absolute_path> is intercepted by
-- network_hook_ctl::vfs_request_handler (src/engine/http_hooks.cc:135) and
-- served via Fetch.fulfillRequest with proper mime. No python http.server needed.
--
-- Windows exception: the VFS handler reads files with std::ifstream in text
-- mode (http_hooks.cc:173) and has no video MIME types at all
-- (src/include/millennium/mime_types.h:30 — CSS/JS/fonts/images/HTML only).
-- Text-mode reads stop at the first 0x1A byte, which every WebM starts with
-- (EBML magic), so video comes back empty -> MEDIA_ERR_SRC_NOT_SUPPORTED.
-- On Windows we serve movies/ over a local python http.server instead.
local FTP_BASE = "https://millennium.ftp"

local HTTP_PORT = 18080
local HTTP_BASE = "http://127.0.0.1:" .. HTTP_PORT
local python_bin = nil
local http_server_started = false

local function url_encode_ftp(s)
    -- mirrors utils::url::encode_url (src/include/millennium/url_parser.h:39):
    -- alnum + - _ . ~ / verbatim, space -> +, rest %XX
    local function enc_char(c)
        local b = string.byte(c)
        if (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122)
           or c == "-" or c == "_" or c == "." or c == "~" or c == "/" then
            return c
        elseif c == " " then
            return "+"
        else
            return string.format("%%%02X", b)
        end
    end
    return (s:gsub("([^%w%-%_%.%~%/ ])", enc_char))
end

local function url_encode_http(s)
    -- RFC 3986 for python http.server: space -> %20 ( NOT "+" ),
    -- unreserved + "/" verbatim, rest %XX (UTF-8 bytes).
    local out = {}
    for i = 1, #s do
        local c = s:sub(i, i)
        local b = string.byte(c)
        if (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122)
           or c == "-" or c == "_" or c == "." or c == "~" or c == "/" then
            out[#out + 1] = c
        else
            out[#out + 1] = string.format("%%%02X", b)
        end
    end
    return table.concat(out)
end

local function ftp_url_from_path(abs_path)
    -- mirrors utils::url::encode_url + get_url_from_path (src/include/millennium/url_parser.h:79)
    -- On Linux: FTP_BASE + encode(path without leading "/")
    local p = abs_path
    if p:sub(1, 1) == "/" then p = p:sub(2) end
    return FTP_BASE .. "/" .. url_encode_ftp(p)
end

local function http_url_for_file(name)
    return HTTP_BASE .. "/" .. url_encode_http(name)
end

local function http_url_for_thumb(name)
    return HTTP_BASE .. "/thumbs/" .. url_encode_http(name)
end

local function movie_url(abs_path, name)
    if IS_WINDOWS then
        return http_url_for_file(name)
    end
    return ftp_url_from_path(abs_path)
end

local function thumb_url(abs_thumb_path, thumb_name)
    if IS_WINDOWS then
        return http_url_for_thumb(thumb_name)
    end
    return ftp_url_from_path(abs_thumb_path)
end

local function trim(s)
    return (s or ""):match("^%s*(.-)%s*$")
end

-- Validate a python candidate by actually running it. Rejects the dead
-- Microsoft Store stub (which prints a Store error instead of "1").
local function try_python_candidate(cmd)
    local probe = string.format('%s -c "print(1)" 2>&1', cmd)
    local h = io.popen(probe)
    if not h then return nil end
    local out = h:read("*a") or ""
    h:close()
    if trim(out) == "1" then
        return cmd
    end
    return nil
end

-- Cache for the validated python command. Every io.popen on Windows flashes
-- a console window at Steam launch, so once validated we persist the command
-- and trust it (absolute paths outside WindowsApps can't be the Store stub).
local function python_cache_path()
    if not thumbs_path then return nil end
    return fs.join(thumbs_path, ".python_bin")
end

local function read_python_cache()
    local cp = python_cache_path()
    if not cp then return nil end
    local f = io.open(cp, "r")
    if not f then return nil end
    local cmd = trim(f:read("*l") or "")
    f:close()
    if cmd == "" then return nil end
    -- Trust absolute paths only; bare commands (python, py -3) are
    -- revalidated below since PATH / launcher state may have changed.
    if cmd:find("\\") or cmd:find("/") then
        local exe = cmd:match('^"([^"]+)"') or cmd:match("^(%S+)")
        if exe and exe:lower():find("windowsapps") == nil and fs.exists(exe) then
            return cmd
        end
    end
    return nil
end

local function write_python_cache(cmd)
    local cp = python_cache_path()
    if not cp then return end
    pcall(function()
        local f = io.open(cp, "w")
        if f then f:write(cmd or ""); f:close() end
    end)
end

local function find_python()
    if python_bin then return python_bin end
    if IS_WINDOWS then
        -- 0-spawn fast path: previously validated absolute path.
        local cached = read_python_cache()
        if cached then
            python_bin = cached
            logger:info("Found python (cached): " .. python_bin)
            return python_bin
        end
        -- 0-spawn pre-filter: only validate files that actually exist.
        -- (Never WindowsApps: the Store stub exists on disk but is dead;
        -- try_python_candidate rejects it by running it.)
        local localapp = os.getenv("LOCALAPPDATA") or ""
        local pfiles = os.getenv("ProgramFiles") or "C:\\Program Files"
        local abs_candidates = {}
        if localapp ~= "" then
            abs_candidates[#abs_candidates + 1] = '"' .. localapp .. '\\Programs\\Python\\Python312\\python.exe"'
            abs_candidates[#abs_candidates + 1] = '"' .. localapp .. '\\Programs\\Python\\Python313\\python.exe"'
            abs_candidates[#abs_candidates + 1] = '"' .. localapp .. '\\Programs\\Python\\Python314\\python.exe"'
        end
        abs_candidates[#abs_candidates + 1] = '"' .. pfiles .. '\\Python312\\python.exe"'
        abs_candidates[#abs_candidates + 1] = '"' .. pfiles .. '\\Python313\\python.exe"'
        abs_candidates[#abs_candidates + 1] = '"C:\\Python312\\python.exe"'
        abs_candidates[#abs_candidates + 1] = '"C:\\Python313\\python.exe"'
        for _, cmd in ipairs(abs_candidates) do
            local exe = cmd:match('^"([^"]+)"') or cmd
            if fs.exists(exe) then
                local ok = try_python_candidate(cmd)
                if ok then
                    python_bin = ok
                    logger:info("Found python: " .. python_bin)
                    write_python_cache(python_bin)
                    return python_bin
                end
                -- Exists but doesn't run: keep checking the rest.
            end
        end
        -- NOTE: no "python3" here — on Windows that name is usually the
        -- dead Store stub, and probing it costs a console flash.
        for _, cmd in ipairs({ "python", "py -3" }) do
            local ok = try_python_candidate(cmd)
            if ok then
                python_bin = ok
                logger:info("Found python: " .. python_bin)
                write_python_cache(python_bin)
                return python_bin
            end
        end
        logger:warn("No working python found - Windows http serving disabled")
        return nil
    end
    for _, cmd in ipairs({ "python3", "python" }) do
        local ok = try_python_candidate(cmd)
        if ok then
            python_bin = ok
            logger:info("Found python: " .. python_bin)
            return python_bin
        end
    end
    logger:warn("No working python found - Windows http serving disabled")
    return nil
end

-- Spawn-free port check via Millennium's built-in http module (libcurl).
-- Every io.popen/os.execute on Windows flashes a console window at Steam
-- launch, so prefer this over powershell/ping probes. Returns nil when the
-- http module is unavailable (caller falls back to spawn probes).
local _http_mod = nil
local function http_serving()
    if _http_mod == nil then
        local ok, mod = pcall(require, "http")
        _http_mod = (ok and mod) or false
    end
    if not _http_mod then return nil end
    local ok, res = pcall(_http_mod.get, HTTP_BASE .. "/", { timeout = 1 })
    if ok and res and res.status then
        return true
    end
    return false
end

local function port_open()
    local via_http = http_serving()
    if via_http ~= nil then return via_http end
    if IS_WINDOWS then
        -- powershell TcpClient probe; prints "open" on success.
        -- Single quotes for the IP survive cmd -> powershell quoting layers.
        local h = io.popen(
            'powershell -NoProfile -Command "try { ' ..
            "$c = New-Object Net.Sockets.TcpClient; " ..
            "$c.Connect('127.0.0.1'," .. HTTP_PORT .. "); " ..
            '$c.Close(); Write-Output open } catch { Write-Output closed }" 2>NUL'
        )
        if h then
            local out = trim(h:read("*a") or "")
            h:close()
            return out == "open"
        end
        return false
    else
        local h = io.popen(
            "(exec 3<>/dev/tcp/127.0.0.1/" .. HTTP_PORT .. ") 2>/dev/null && echo open || echo closed"
        )
        if h then
            local out = trim(h:read("*a") or "")
            h:close()
            return out == "open"
        end
        return false
    end
end

local function start_http_server()
    if http_server_started then return true end
    if port_open() then
        -- Something (maybe a previous instance) already serves the port.
        http_server_started = true
        logger:info("http server already listening on " .. HTTP_PORT)
        return true
    end
    local py = find_python()
    if not py then return false end
    if not movies_path then return false end

    if IS_WINDOWS then
        -- Serve with windowless pythonw.exe when available: python.exe is a
        -- console app, so the server would otherwise hold a visible console
        -- window open for the entire Steam session. Validation still uses
        -- python.exe (pythonw can't print the "1" probe to a pipe).
        local srv = py
        local w = py:gsub("python%.exe", "pythonw.exe", 1):gsub("^python$", "pythonw"):gsub("^py ", "pyw ")
        local w_exe = w:match('^"([^"]+)"') or w:match("^(%S+)")
        -- Gate absolute paths on existence; bare names (pythonw on PATH
        -- next to python) are trusted — resolving them costs a spawn.
        if w_exe and (w_exe:find("\\") or w_exe:find("/")) then
            if fs.exists(w_exe) then srv = w end
        else
            srv = w
        end
        -- start /B detaches; > NUL 2>&1 keeps Steam logs clean.
        local cmd = string.format(
            'start "" /B %s -m http.server %d --bind 127.0.0.1 --directory "%s" > NUL 2>&1',
            srv, HTTP_PORT, movies_path
        )
        os.execute(cmd)
    else
        local cmd = string.format(
            '%s -m http.server %d --bind 127.0.0.1 --directory "%s" >/dev/null 2>&1 &',
            py, HTTP_PORT, movies_path
        )
        os.execute(cmd)
    end

    -- Poll for the port to come up. http_serving() is spawn-free with a
    -- 1s timeout, so ~5 tries ≈ 5s max with zero console flashes.
    for _ = 1, 5 do
        if port_open() then
            http_server_started = true
            logger:info("http server listening on " .. HTTP_BASE .. " (dir: " .. movies_path .. ")")
            return true
        end
    end
    logger:warn("http server failed to bind port " .. HTTP_PORT)
    return false
end

local function stop_http_server()
    if not http_server_started then return end
    http_server_started = false
    if not IS_WINDOWS then return end
    -- Kill only the process bound to our port (never blanket python.exe).
    local ok, _ = pcall(function()
        local h = io.popen('netstat -ano 2>NUL | findstr ":' .. HTTP_PORT .. '" | findstr LISTENING')
        if not h then return end
        local out = h:read("*a") or ""
        h:close()
        -- Collect trailing PIDs from each LISTENING line, kill each once.
        local pids = {}
        for line in out:gmatch("[^\r\n]+") do
            local pid = line:match("(%d+)%s*$")
            if pid and pid ~= "0" then pids[pid] = true end
        end
        for pid, _ in pairs(pids) do
            logger:info("Stopping http server PID " .. pid)
            os.execute("taskkill /PID " .. pid .. " /F > NUL 2>&1")
        end
    end)
    if not ok then
        logger:warn("http server cleanup failed (port " .. HTTP_PORT .. " may linger)")
    end
end

local function find_ffmpeg()
    if ffmpeg_bin then return ffmpeg_bin end
    if IS_WINDOWS then
        -- 0-spawn fast path: winget link + usual install spots first.
        -- `where` flashes a console, so it is the fallback, not the default.
        local localapp = os.getenv("LOCALAPPDATA") or ""
        local pfiles = os.getenv("ProgramFiles") or "C:\\Program Files"
        local abs = {}
        if localapp ~= "" then
            abs[#abs + 1] = localapp .. "\\Microsoft\\WinGet\\Links\\ffmpeg.exe"
        end
        abs[#abs + 1] = pfiles .. "\\ffmpeg\\bin\\ffmpeg.exe"
        abs[#abs + 1] = "C:\\ffmpeg\\bin\\ffmpeg.exe"
        for _, exe in ipairs(abs) do
            if fs.exists(exe) then
                ffmpeg_bin = exe
                logger:info("Found ffmpeg: " .. ffmpeg_bin)
                return ffmpeg_bin
            end
        end
    end
    local probe
    if IS_WINDOWS then
        probe = "where ffmpeg 2>NUL"
    else
        probe = "which ffmpeg 2>/dev/null"
    end
    local handle = io.popen(probe)
    if handle then
        local result = trim(handle:read("*a") or "")
        handle:close()
        -- `where` can list several lines; take the first .exe that exists.
        local first = result:match("([^\r\n]+)")
        if first and first ~= "" then
            ffmpeg_bin = trim(first)
            logger:info("Found ffmpeg: " .. ffmpeg_bin)
            return ffmpeg_bin
        end
    end
    logger:warn("ffmpeg not found on PATH - thumbnail generation disabled")
    return nil
end

local _has_autoplay_flag = nil
local function has_autoplay_flag()
    if _has_autoplay_flag ~= nil then return _has_autoplay_flag end
    -- NOTE: this only observes whether steamwebhelper runs with
    -- --autoplay-policy (unmuted autoplay available, shipped stock by Steam).
    local h
    if IS_WINDOWS then
        h = io.popen('tasklist /V 2>NUL | findstr /I "autoplay-policy" >NUL && echo yes || echo no')
    else
        h = io.popen("ps aux 2>/dev/null | grep -q 'autoplay-policy' && echo yes || echo no")
    end
    if h then
        local r = h:read("*a") or ""
        h:close()
        _has_autoplay_flag = r:find("yes") ~= nil
        if _has_autoplay_flag then
            logger:info("Observed --autoplay-policy in steamwebhelper cmdline (unmuted autoplay available)")
        else
            logger:info("No --autoplay-policy flag - using muted-first hybrid fallback")
        end
        return _has_autoplay_flag
    end
    _has_autoplay_flag = false
    return false
end

-- Video extensions Chromium (steamwebhelper) can actually decode.
-- Listed broadly; unplayable files fail gracefully in the frontend (onError -> dismiss).
local VIDEO_EXTS = {
    [".webm"] = true,
    [".mp4"] = true,
    [".m4v"] = true,
    [".mov"] = true,
    [".mkv"] = true,
    [".ogv"] = true,
    [".ogg"] = true,
}

local function is_video_file(name)
    local ext = fs.extension(name)
    if not ext or ext == "" then return false, nil end
    ext = ext:lower()
    return VIDEO_EXTS[ext] == true, ext
end

local function ensure_movies_dir()
    if movies_path then
        return movies_path
    end

    local backend_path = MILLENNIUM_PLUGIN_SECRET_BACKEND_ABSOLUTE
    if not backend_path then
        logger:error("Could not determine plugin path")
        return nil
    end

    local plugin_path = fs.parent_path(backend_path)
    local path = fs.join(plugin_path, "movies")
    if not fs.exists(path) then
        logger:warn("movies directory does not exist: " .. path)
        return nil
    end

    movies_path = path

    local thumbs = fs.join(path, "thumbs")
    local ok, err = fs.create_directories(thumbs)
    if fs.exists(thumbs) then
        thumbs_path = thumbs
        logger:info("Thumbnails directory: " .. thumbs)
    else
        logger:warn("Could not create thumbnails directory: " .. thumbs .. " (" .. tostring(err) .. ")")
    end

    return movies_path
end

local function generate_thumbnail(movie_path, movie_name)
    if not thumbs_path or not ffmpeg_bin then return nil end

    local ok, thumb_url_or_nil = pcall(function()
        local movie_ext = movie_name:match("%.([^%.]+)$") or ""
        -- ext has NO dot here, so drop #ext + 1 (dot) chars: sub end = -(#ext + 2)
        local base = movie_name:sub(1, -(#movie_ext + 2))
        local thumb_name = base .. ".jpg"
        local thumb_path = fs.join(thumbs_path, thumb_name)

        if not fs.exists(thumb_path) then
            local cmd
            if IS_WINDOWS then
                cmd = string.format(
                    'start "" /B "%s" -y -i "%s" -ss 00:00:01 -vframes 1 -q:v 2 "%s" > NUL 2>&1',
                    ffmpeg_bin, movie_path, thumb_path
                )
            else
                cmd = string.format(
                    '"%s" -y -i "%s" -ss 00:00:01 -vframes 1 -q:v 2 "%s" 2>/dev/null &',
                    ffmpeg_bin, movie_path, thumb_path
                )
            end
            os.execute(cmd)
            return nil
        end

        return thumb_url(thumb_path, thumb_name)
    end)
    if not ok then
        logger:warn("Thumbnail failed for '" .. tostring(movie_name) .. "': " .. tostring(thumb_url_or_nil))
        return nil
    end
    return thumb_url_or_nil
end

function json_encode(obj)
    if type(obj) == "string" then
        return '"' .. obj:gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
    elseif type(obj) == "number" then
        return tostring(obj)
    elseif type(obj) == "boolean" then
        return tostring(obj)
    elseif type(obj) == "nil" then
        return "null"
    elseif type(obj) == "table" then
        local is_array = true
        local max_key = 0
        for k, _ in pairs(obj) do
            if type(k) ~= "number" or k <= 0 then is_array = false break end
            if k > max_key then max_key = k end
        end
        if is_array and max_key == #obj then
            local parts = {}
            for i = 1, #obj do parts[i] = json_encode(obj[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, v in pairs(obj) do parts[#parts + 1] = json_encode(k) .. ":" .. json_encode(v) end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    else
        return tostring(obj)
    end
end

function get_movies()
    if cached_movies then return cached_movies end

    local ok, result_json = pcall(function()
        local path = ensure_movies_dir()
        if not path then return "[]" end

        if IS_WINDOWS and not http_server_started then
            start_http_server()
        end

        local entries, err = fs.list(path)
        if not entries then
            logger:error("Failed to list movies dir '" .. tostring(path) .. "': " .. tostring(err))
            return "[]"
        end

        local result = {}
        local seen = {}
        local skipped = 0
        local ok_sort, sort_err = pcall(table.sort, entries, function(a, b) return (a.name or "") < (b.name or "") end)
        if not ok_sort then
            logger:warn("Could not sort movie entries: " .. tostring(sort_err))
        end
        for _, entry in ipairs(entries) do
            local ok_entry, entry_err = pcall(function()
                if entry.is_file and entry.name then
                    local name = entry.name
                    local is_video, ext = is_video_file(name)
                    if is_video then
                        local base = name:sub(1, -(#ext + 1)):lower()
                        if not seen[base] then
                            seen[base] = true
                            local abs_path = fs.join(path, name)
                            local url = movie_url(abs_path, name)
                            local thumb = generate_thumbnail(abs_path, name)
                            table.insert(result, {
                                name = name,
                                size = entry.size or 0,
                                url = url,
                                thumb = thumb
                            })
                        end
                    else
                        skipped = skipped + 1
                    end
                end
            end)
            if not ok_entry then
                logger:warn("Skipping bad movie entry '" .. tostring(entry and entry.name) .. "': " .. tostring(entry_err))
            end
        end

        if skipped > 0 then
            logger:info("Skipped " .. skipped .. " non-video file(s) in movies/")
        end
        cached_count = #result
        return json_encode(result)
    end)

    if not ok then
        logger:error("get_movies failed: " .. tostring(result_json))
        return "[]"
    end

    cached_movies = result_json
    return cached_movies
end

function refresh_movies()
    cached_movies = nil
    return get_movies()
end

local function on_load()
    if IS_WINDOWS then
        logger:info("Startup Movies plugin loaded (windows/http http.server)")
    else
        logger:info("Startup Movies plugin loaded (dev/ftp VFS - no python server)")
    end

    millennium.add_browser_css("frontend/steam-hide.css")
    millennium.add_browser_js("frontend/steam-hide.js")

    find_ffmpeg()
    if IS_WINDOWS then
        -- movies_path must exist before the server can bind --directory to it.
        ensure_movies_dir()
        start_http_server()
    end
    get_movies()
    if IS_WINDOWS then
        logger:info("Found " .. cached_count .. " movie files (served via " .. HTTP_BASE .. ")")
    else
        logger:info("Found " .. cached_count .. " movie files (served via https://millennium.ftp)")
    end

    millennium.ready()
end

local function on_unload()
    stop_http_server()
    logger:info("Startup Movies plugin unloaded")
end

function get_status()
    return json_encode({
        has_ffmpeg = ffmpeg_bin ~= nil,
        has_autoplay_flag = has_autoplay_flag(),
        ftp_serving = not IS_WINDOWS,
        http_serving = IS_WINDOWS and http_server_started,
        is_windows = IS_WINDOWS,
        has_python = python_bin ~= nil,
        http_port = HTTP_PORT
    })
end

function log_message(message)
    logger:info(message)
end

return {
    on_load = on_load,
    on_unload = on_unload,
    get_movies = get_movies,
    refresh_movies = refresh_movies,
    get_status = get_status,
    log_message = log_message
}
