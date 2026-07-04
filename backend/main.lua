local millennium = require("millennium")
local fs = require("fs")
local logger = require("logger")

local movies_path = nil
local server_pid = nil
local server_url = nil
local cached_movies = nil
local cached_count = 0

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
    return movies_path
end

local function json_encode(obj)
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
                    local url = server_url and (server_url .. name) or nil
                    table.insert(result, {
                        name = name,
                        size = entry.size,
                        url = url
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

    local port = 18080
    local cmd = string.format('python3 -m http.server %d --directory "%s" > /dev/null 2>&1 & echo $!', port, movies_path)
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

    logger:warn("Failed to start movie HTTP server on port " .. port)
    return nil
end

local function on_load()
    logger:info("Startup Movies plugin loaded")

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

function log_message(message)
    logger:info(message)
end

return {
    on_load = on_load,
    on_unload = on_unload,
    get_movies = get_movies,
    log_message = log_message
}
