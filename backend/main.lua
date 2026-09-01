local millennium = require("millennium")
local fs = require("fs")
local logger = require("logger")

local movies_path = nil
local thumbs_path = nil
local cached_movies = nil
local cached_count = 0
local ffmpeg_bin = nil

-- Millennium ftp VFS: https://millennium.ftp/<absolute_path> is intercepted by
-- network_hook_ctl::vfs_request_handler (src/engine/http_hooks.cc:138) and
-- served via Fetch.fulfillRequest with proper mime. No python http.server needed.
local FTP_BASE = "https://millennium.ftp"

-- Platform detection and shell helpers (Linux vs Windows)
local IS_WINDOWS = package.config:sub(1,1) == "\\"
local SHELL_WHICH = IS_WINDOWS and "where ffmpeg" or "which ffmpeg 2>/dev/null"

local function ftp_url_from_path(abs_path)
    -- mirrors utils::url::encode_url + get_url_from_path (src/include/millennium/url_parser.h:79)
    -- On Linux: FTP_BASE + encode(path without leading "/")
    -- On Windows: FTP_BASE + encode(path with "/" separators, no leading "/")
    local p = abs_path
    if IS_WINDOWS then
        -- normalize separators; keep drive prefix (C:/...) so it mirrors get_url_from_path
        p = p:gsub("\\", "/")
        if p:sub(1,1) == "/" then p = p:sub(2) end
    else
        if p:sub(1,1) == "/" then p = p:sub(2) end
    end
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
    local enc = p:gsub("([^%w%-%_%.%~%/ ])", enc_char)
    return FTP_BASE .. "/" .. enc
end

local function find_ffmpeg()
    if ffmpeg_bin then return ffmpeg_bin end
    local handle = io.popen(SHELL_WHICH)
    if handle then
        local result = handle:read("*a")
        handle:close()
        -- multiple matches possible on Windows (ffmpeg.exe); take first line.
        -- reject the "INFO: Could not find files..." stdout that `where` prints when missing.
        result = result:match("^[^\r\n]+") or ""
        result = result:gsub("[ \t\r\n]+$", "")
        if result ~= "" and not result:find("INFO: Could not find", 1, true) and result:lower():find("ffmpeg") then
            ffmpeg_bin = result
            logger:info("Found ffmpeg: " .. ffmpeg_bin)
            return ffmpeg_bin
        end
    end
    logger:warn("ffmpeg not found on PATH - thumbnail generation disabled")
    return nil
end

local _has_autoplay_patch = nil
local function has_autoplay_patch()
    if _has_autoplay_patch ~= nil then return _has_autoplay_patch end
    -- check steamwebhelper cmdline for --autoplay-policy flag (patched Millennium)
    local detected = false
    if IS_WINDOWS then
        -- Windows: steamwebhelper.exe command line via wmic (XP+/works without extra deps)
        local h = io.popen('wmic process where "name=\'steamwebhelper.exe\'" get commandline /value 2>NUL')
        if h then
            local r = h:read("*a") or ""
            h:close()
            detected = r:find("autoplay%-policy") ~= nil
        end
        -- fallback: check installed Millennium lib presence of the flag is unreliable on Windows
        -- (dll injection differs); if wmic gave nothing, treat as stock -> hybrid fallback
    else
        local h = io.popen("ps aux 2>/dev/null | grep -q 'autoplay-policy' && echo yes || echo no")
        if h then
            local r = h:read("*a") or ""
            h:close()
            detected = r:find("yes") ~= nil
        end
    end
    _has_autoplay_patch = detected
    if _has_autoplay_patch then
        logger:info("Detected autoplay patch (steamwebhelper has --autoplay-policy)")
    else
        logger:info("No autoplay patch - using muted-first hybrid fallback")
    end
    return _has_autoplay_patch
end

local _startup_cache = nil
local function get_startup_location_info()
    if _startup_cache ~= nil then return _startup_cache end

    local candidate_paths = {}
    local sep = IS_WINDOWS and "\\" or "/"
    local home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""

    if IS_WINDOWS then
        -- Windows Steam keeps per-user config (StartupLocation lives here)
        local appdata = os.getenv("APPDATA") or ""
        if appdata ~= "" then candidate_paths[#candidate_paths+1] = appdata .. sep .. "Steam" .. sep .. "config" .. sep .. "config.vdf" end
        if home ~= "" then
            candidate_paths[#candidate_paths+1] = home .. sep .. "AppData" .. sep .. "Local" .. sep .. "Steam" .. sep .. "config" .. sep .. "config.vdf"
            candidate_paths[#candidate_paths+1] = home .. sep .. "Application Data" .. sep .. "Steam" .. sep .. "config" .. sep .. "config.vdf"
        end
        -- install dir stubs (forward slashes also accepted by io.open on Windows)
    else
        if home ~= "" then
            candidate_paths[#candidate_paths+1] = home .. "/.steam/steam/config/config.vdf"
            candidate_paths[#candidate_paths+1] = home .. "/.local/share/Steam/config/config.vdf"
            candidate_paths[#candidate_paths+1] = home .. "/.steam/config/config.vdf"
            candidate_paths[#candidate_paths+1] = home .. "/.steam/root/config/config.vdf"
            candidate_paths[#candidate_paths+1] = home .. "/.var/app/com.valvesoftware.Steam/config/config.vdf"
            -- flatpak / snap variants
            candidate_paths[#candidate_paths+1] = home .. "/snap/steam/common/.steam/steam/config/config.vdf"
        end
    end
    local prog86 = os.getenv("ProgramFiles(x86)") or os.getenv("PROGRAMFILES(X86)") or ""
    if prog86 ~= "" then candidate_paths[#candidate_paths+1] = prog86 .. "/Steam/config/config.vdf" end
    local prog = os.getenv("PROGRAMFILES") or os.getenv("ProgramFiles") or ""
    if prog ~= "" and prog ~= prog86 then candidate_paths[#candidate_paths+1] = prog .. "/Steam/config/config.vdf" end
    local steam_path = os.getenv("STEAM_PATH") or ""
    if steam_path ~= "" then candidate_paths[#candidate_paths+1] = steam_path .. "/config/config.vdf" end

    local raw_value = nil
    local found_path = nil

    for _, p in ipairs(candidate_paths) do
        local f = io.open(p, "r")
        if f then
            local content = f:read("*a") or ""
            f:close()
            if content ~= "" then
                found_path = p
                local lower = content:lower()
                -- Look for any key containing "startup" with a quoted value
                -- Example: "StartupLocation"  "1"  or "startupwindow" "library"
                for key, val in lower:gmatch('"([^"]*startup[^"]*)"%s+"([^"]*)"') do
                    raw_value = val
                    logger:info("Found startup key '" .. key .. "' = '" .. val .. "' in " .. p)
                    break
                end
                -- Also try unquoted numeric form: "StartupLocation"  "0" is covered above, but also check without second quotes?
                if not raw_value then
                    for key, val in lower:gmatch('"([^"]*startup[^"]*)"%s+([%w%p]+)') do
                        raw_value = val:gsub('"','')
                        logger:info("Found startup key (unquoted) '" .. key .. "' = '" .. raw_value .. "' in " .. p)
                        break
                    end
                end
                if raw_value then break end
            end
        end
    end

    if not raw_value then
        logger:info("Startup Location not found in config.vdf (checked " .. #candidate_paths .. " paths) - requires manual Library setting")
        _startup_cache = { found = false, raw = nil, is_library = nil, path = nil }
        return _startup_cache
    end

    -- Normalize: trim, remove quotes
    raw_value = raw_value:gsub('^%s*"',''):gsub('"%s*$',''):gsub("^%s+",""):gsub("%s+$","")
    local is_library = nil
    if raw_value:find("libr") then
        is_library = true
    elseif raw_value == "0" then
        -- Heuristic: 0 often maps to Library (default) on Steam
        is_library = true
    elseif raw_value:match("^%d+$") then
        -- Any other numeric value likely means Store/Friends/etc, not Library
        is_library = false
    elseif raw_value == "library" or raw_value == "default" then
        is_library = true
    else
        -- String without "libr" => not library (e.g. "store")
        is_library = false
    end

    logger:info("Startup Location raw='" .. tostring(raw_value) .. "' is_library=" .. tostring(is_library) .. " path=" .. tostring(found_path))
    _startup_cache = { found = true, raw = raw_value, is_library = is_library, path = found_path }
    return _startup_cache
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
    if IS_WINDOWS then
        os.execute(string.format('powershell -NoProfile -Command "New-Item -ItemType Directory -Force -Path \'%s\' | Out-Null"', thumbs))
    else
        os.execute('mkdir -p "' .. thumbs .. '" 2>/dev/null')
    end
    if fs.exists(thumbs) then
        thumbs_path = thumbs
        logger:info("Thumbnails directory: " .. thumbs)
    else
        logger:warn("Could not create thumbnails directory: " .. thumbs)
    end

    return movies_path
end

local function generate_thumbnail(movie_path, movie_name)
    if not thumbs_path or not ffmpeg_bin then return nil end

    local base = movie_name:sub(1, -(#movie_name:match("%.([^%.]+)$") or 0) - 2)
    local thumb_name = base .. ".jpg"
    local thumb_path = fs.join(thumbs_path, thumb_name)

    if not fs.exists(thumb_path) then
        -- Windows: PowerShell start-process for async so os.execute doesn't block on spawned ffmpeg
        local redirect = IS_WINDOWS and '2>$null' or '2>/dev/null'
        local cmd
        if IS_WINDOWS then
            cmd = string.format(
                'powershell -NoProfile -Command "Start-Process -FilePath \'%s\' -ArgumentList \'-y\',\'-i\',\'%s\',\'-ss\',\'00:00:01\',\'-vframes\',\'1\',\'-q:v\',\'2\',\'%s\' -WindowStyle Hidden -Wait" %s',
                ffmpeg_bin, movie_path, thumb_path, redirect
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

    return ftp_url_from_path(thumb_path)
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

    local path = ensure_movies_dir()
    if not path then return "[]" end

    local entries, err = fs.list(path)
    if not entries then
        logger:error("Failed to list movies: " .. tostring(err))
        return "[]"
    end

    local result = {}
    local seen = {}
    for _, entry in ipairs(entries) do
        if entry.is_file then
            local name = entry.name
            local ext = fs.extension(name)
            if ext == ".webm" or ext == ".mp4" then
                local base = name:sub(1, -(#ext + 1))
                if not seen[base] then
                    seen[base] = true
                    local abs_path = fs.join(path, name)
                    local url = ftp_url_from_path(abs_path)
                    local thumb = generate_thumbnail(abs_path, name)
                    table.insert(result, {
                        name = name,
                        size = entry.size,
                        url = url,
                        thumb = thumb
                    })
                end
            end
        end
    end

    cached_movies = json_encode(result)
    cached_count = #result
    return cached_movies
end

local function on_load()
    logger:info("Startup Movies plugin loaded (dev/ftp VFS - no python server)")

    millennium.add_browser_css("frontend/steam-hide.css")
    millennium.add_browser_js("frontend/steam-hide.js")

    find_ffmpeg()
    get_movies()
    logger:info("Found " .. cached_count .. " movie files (served via https://millennium.ftp)")

    millennium.ready()
end

local function on_unload()
    logger:info("Startup Movies plugin unloaded")
end

function get_status()
    local startup = get_startup_location_info()
    return json_encode({
        has_ffmpeg = ffmpeg_bin ~= nil,
        movie_count = cached_count,
        has_autoplay_patch = has_autoplay_patch(),
        ftp_serving = true,
        startup_found = startup.found,
        startup_raw = startup.raw,
        startup_is_library = startup.is_library,
        startup_path = startup.path
    })
end

function log_message(message)
    logger:info(message)
end

return {
    on_load = on_load,
    on_unload = on_unload,
    get_movies = get_movies,
    get_status = get_status,
    log_message = log_message
}
