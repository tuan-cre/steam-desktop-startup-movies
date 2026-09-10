local millennium = require("millennium")
local fs = require("fs")
local logger = require("logger")

local IS_WINDOWS = package.config:sub(1, 1) == "\\"

local movies_path = nil
local thumbs_path = nil
local cached_movies = nil
local cached_count = 0
local ffmpeg_bin = nil

-- Serving model.
-- Linux: Millennium ftp VFS, https://millennium.ftp/<absolute_path>,
-- intercepted by network_hook_ctl::vfs_request_handler
-- (Millennium src/engine/http_hooks.cc:135). No local server needed.
-- Windows: the VFS handler reads files with std::ifstream in text mode
-- (http_hooks.cc:173) and has no video MIME types at all
-- (src/include/millennium/mime_types.h:30 — CSS/JS/fonts/images/HTML only).
-- Text-mode reads stop at the first 0x1A byte, which every WebM starts with
-- (EBML magic), so video comes back empty -> MEDIA_ERR_SRC_NOT_SUPPORTED
-- (verified live: FTP playback flashes black 0.1s then dismisses).
-- Windows therefore embeds movies as base64 data URLs (read + encoded
-- in-process: zero spawned consoles, zero python dependency, zero ports).
-- One movie is ever embedded at a time (the one about to play), so peak
-- cost is ~1.33x a single file. Files over DATA_MAX_BYTES are refused.
local FTP_BASE = "https://millennium.ftp"

local DATA_MAX_BYTES = 64 * 1024 * 1024

local DATA_VIDEO_MIME = {
    [".webm"] = "video/webm",
    [".mp4"] = "video/mp4",
    [".m4v"] = "video/mp4",
    [".mov"] = "video/quicktime",
    [".mkv"] = "video/x-matroska",
    [".ogv"] = "video/ogg",
    [".ogg"] = "video/ogg",
}

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

local function ftp_url_from_path(abs_path)
    -- mirrors utils::url::encode_url + get_url_from_path (src/include/millennium/url_parser.h:79)
    -- On Linux: FTP_BASE + encode(path without leading "/")
    local p = abs_path
    if p:sub(1, 1) == "/" then p = p:sub(2) end
    return FTP_BASE .. "/" .. url_encode_ftp(p)
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

local function trim(s)
    return (s or ""):match("^%s*(.-)%s*$")
end

local function base64_of_file(abs_path)
    local f = io.open(abs_path, "rb")
    if not f then return nil end
    local bytes = f:read("*a") or ""
    f:close()
    if #bytes == 0 or #bytes > DATA_MAX_BYTES then
        return nil, #bytes
    end
    local has_utils, utils = pcall(require, "utils")
    if not has_utils or not utils or not utils.base64_encode then
        return nil, #bytes
    end
    local b64 = utils.base64_encode(bytes)
    if not b64 or b64 == "" then return nil, #bytes end
    return b64, #bytes
end

local function find_ffmpeg()
    if ffmpeg_bin then return ffmpeg_bin end
    if IS_WINDOWS then
        -- fs.exists checks first: `where` flashes a console, so it stays
        -- the fallback. (Thumbnail generation is the only remaining spawn,
        -- and only fires while a thumb is missing.)
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

-- NOTE: no autoplay-policy probing (Linux `ps` / Windows `tasklist`).
-- Playback starts muted and unmutes opportunistically (tryUnmute in the
-- frontend); the flag only ever fed a log line and an undisplayed status
-- field, so the probes were pure cost. Steam ships --autoplay-policy stock.

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

local function thumb_name_for(movie_name)
    local movie_ext = movie_name:match("%.([^%.]+)$") or ""
    -- ext has NO dot here, so drop #ext + 1 (dot) chars: sub end = -(#ext + 2)
    local base = movie_name:sub(1, -(#movie_ext + 2))
    return base .. ".jpg"
end

local function generate_thumbnail(movie_path, movie_name)
    if not thumbs_path or not ffmpeg_bin then return nil end

    local ok, thumb_url_or_nil = pcall(function()
        local thumb_name = thumb_name_for(movie_name)
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

        if IS_WINDOWS then
            -- List carries existence only; bytes resolve on demand via
            -- get_thumb_data (see generate_thumbnail's true below).
            return true -- exists; frontend fetches bytes via get_thumb_data
        end
        return ftp_url_from_path(thumb_path)
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

-- Reject anything but a bare filename (no traversal).
local function clean_name(arg)
    local name = nil
    if type(arg) == "string" then
        name = arg
    elseif type(arg) == "table" then
        name = arg.name
    end
    if not name or name == "" then return nil end
    if name:find("[/\\]") or name:find("%.%.") then
        logger:warn("rejected bad name '" .. tostring(name) .. "'")
        return nil
    end
    return name
end

function get_movies()
    if cached_movies then return cached_movies end

    local ok, result_json = pcall(function()
        local path = ensure_movies_dir()
        if not path then return "[]" end

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
                            local item = {
                                name = name,
                                size = entry.size or 0,
                            }
                            if IS_WINDOWS then
                                -- Windows: URLs resolve on demand via
                                -- get_movie_data / get_thumb_data (embedded
                                -- data). Nothing to spawn or serve here.
                                item.has_thumb = generate_thumbnail(fs.join(path, name), name) ~= nil
                            else
                                local abs_path = fs.join(path, name)
                                item.url = ftp_url_from_path(abs_path)
                                item.thumb = generate_thumbnail(abs_path, name)
                            end
                            table.insert(result, item)
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

-- Windows: embed one movie as a data URL (the one about to play).
-- Single-file weight only; oversized files are refused.
function get_movie_data(arg)
    local name = clean_name(arg)
    if not name then return nil end
    local ok, url = pcall(function()
        local path = ensure_movies_dir()
        if not path then return nil end
        local is_video, ext = is_video_file(name)
        if not is_video then return nil end
        local abs = fs.join(path, name)
        if not fs.exists(abs) then return nil end
        local b64, size = base64_of_file(abs)
        if not b64 then
            logger:warn("get_movie_data: '" .. name .. "' unreadable or size " .. tostring(size) .. " out of range")
            return nil
        end
        return "data:" .. (DATA_VIDEO_MIME[ext] or "video/webm") .. ";base64," .. b64
    end)
    if not ok then
        logger:warn("get_movie_data failed: " .. tostring(url))
        return nil
    end
    return url
end

-- Windows: embed one thumbnail as a data URL (tiny jpg).
function get_thumb_data(arg)
    local name = clean_name(arg)
    if not name then return nil end
    local ok, url = pcall(function()
        ensure_movies_dir()
        if not thumbs_path then return nil end
        local is_video = is_video_file(name)
        if not is_video then return nil end
        local abs = fs.join(thumbs_path, thumb_name_for(name))
        if not fs.exists(abs) then return nil end
        local b64, size = base64_of_file(abs)
        if not b64 then return nil end
        return "data:image/jpeg;base64," .. b64
    end)
    if not ok then
        logger:warn("get_thumb_data failed: " .. tostring(url))
        return nil
    end
    return url
end

local function on_load()
    if IS_WINDOWS then
        logger:info("Startup Movies plugin loaded (windows/data embedded, zero processes)")
    else
        logger:info("Startup Movies plugin loaded (dev/ftp VFS - no python server)")
    end

    millennium.add_browser_css("frontend/steam-hide.css")
    millennium.add_browser_js("frontend/steam-hide.js")

    find_ffmpeg()
    get_movies()
    if IS_WINDOWS then
        logger:info("Found " .. cached_count .. " movie files (embedded data URLs)")
    else
        logger:info("Found " .. cached_count .. " movie files (served via https://millennium.ftp)")
    end

    millennium.ready()
end

local function on_unload()
    logger:info("Startup Movies plugin unloaded")
end

function get_status()
    return json_encode({
        has_ffmpeg = ffmpeg_bin ~= nil,
        ftp_serving = not IS_WINDOWS,
        data_serving = IS_WINDOWS,
        is_windows = IS_WINDOWS
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
    log_message = log_message,
    get_movie_data = get_movie_data,
    get_thumb_data = get_thumb_data
}
