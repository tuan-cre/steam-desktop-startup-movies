local millennium = require("millennium")
local fs = require("fs")
local logger = require("logger")

local movies_path = nil
local thumbs_path = nil
local server_pid = nil
local server_url = nil
local cached_movies = nil
local cached_count = 0
local python_bin = nil
local ffmpeg_bin = nil

local function find_python()
    if python_bin then return python_bin end
    local handle = io.popen("which python3 2>/dev/null")
    if handle then
        local result = handle:read("*a")
        handle:close()
        result = result:match("^%s*(.-)%s*$")
        if result and result ~= "" then
            python_bin = result
            logger:info("Found python3: " .. python_bin)
            return python_bin
        end
    end
    logger:error("python3 not found on PATH - HTTP server will not start")
    return nil
end

local function find_ffmpeg()
    if ffmpeg_bin then return ffmpeg_bin end
    local handle = io.popen("which ffmpeg 2>/dev/null")
    if handle then
        local result = handle:read("*a")
        handle:close()
        result = result:match("^%s*(.-)%s*$")
        if result and result ~= "" then
            ffmpeg_bin = result
            logger:info("Found ffmpeg: " .. ffmpeg_bin)
            return ffmpeg_bin
        end
    end
    logger:warn("ffmpeg not found on PATH - thumbnail generation disabled")
    return nil
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
    os.execute('mkdir -p "' .. thumbs .. '" 2>/dev/null')
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
        local cmd = string.format(
            '"%s" -y -i "%s" -ss 00:00:01 -vframes 1 -q:v 2 "%s" 2>/dev/null &',
            ffmpeg_bin, movie_path, thumb_path
        )
        os.execute(cmd)
        return nil
    end

    return server_url and (server_url .. "thumbs/" .. thumb_name) or nil
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

    if server_pid then
        local alive = io.popen("kill -0 " .. server_pid .. " 2>/dev/null && echo yes || echo no")
        local status = alive:read("*a")
        alive:close()
        if not status:find("yes") then
            logger:warn("HTTP server (pid=" .. server_pid .. ") died, restarting...")
            server_pid = nil
            server_url = nil
            cached_movies = nil
            start_http_server()
        end
    end

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
                    local url = server_url and (server_url .. name) or nil
                    local thumb = generate_thumbnail(fs.join(path, name), name)
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

local function start_http_server()
    if not movies_path then return nil end
    if not python_bin then return nil end

    local base_port = 18080
    local max_tries = 6

    for i = 0, max_tries - 1 do
        local port = base_port + i
        local cmd = string.format('%s -m http.server %d --directory "%s" > /dev/null 2>&1 & echo $!', python_bin, port, movies_path)
        local handle = io.popen(cmd)
        local pid_str = handle:read("*a")
        handle:close()

        local pid = tonumber(pid_str:match("%d+"))
        if pid then
            os.execute("sleep 0.3")
            local alive = io.popen("kill -0 " .. pid .. " 2>/dev/null && echo yes || echo no")
            local status = alive:read("*a")
            alive:close()
            if status:find("yes") then
                server_pid = pid
                server_url = string.format("http://127.0.0.1:%d/", port)
                logger:info(string.format("Movie HTTP server on port %d (pid=%d)", port, pid))
                return server_url
            end
        end
    end

    logger:error("Failed to start movie HTTP server on ports " .. base_port .. "-" .. (base_port + max_tries - 1))
    return nil
end

local function on_load()
    logger:info("Startup Movies plugin loaded")

    millennium.add_browser_js("frontend/steam-hide.js")

    find_python()
    find_ffmpeg()
    get_movies()
    logger:info("Found " .. cached_count .. " movie files")

    start_http_server()
    cached_movies = nil
    millennium.ready()
end

local function on_unload()
    logger:info("Startup Movies plugin unloaded")
    if server_pid then
        os.execute("kill " .. server_pid .. " 2>/dev/null")
        server_pid = nil
        server_url = nil
    end
end

function get_status()
    return json_encode({
        has_python = python_bin ~= nil,
        has_ffmpeg = ffmpeg_bin ~= nil,
        server_running = server_pid ~= nil,
        movie_count = cached_count
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
