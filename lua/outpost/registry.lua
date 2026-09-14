-- Registry: local cache of known sessions for completion and display.
-- Never authoritative.

local M = {}

local FILENAME = "sessions.json"

local function file(dir)
    return vim.fs.joinpath(dir, FILENAME)
end

local function read(dir)
    if not vim.uv.fs_stat(file(dir)) then
        return {}
    end

    local lines = vim.fn.readfile(file(dir))
    local ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))

    if not ok or type(decoded) ~= "table" then
        return {}
    end

    return decoded
end

local function write(dir, sessions)
    vim.fn.writefile({ vim.json.encode(sessions) }, file(dir))
end

-- Record (or refresh) one session entry, keyed by session id.
function M.record(dir, entry)
    local sessions = read(dir)
    local key = entry.session_id

    sessions[key] = {
        endpoint = entry.endpoint,
        canonical_path = entry.canonical_path,
        typed_target = entry.typed_target,
        ["last-used"] = os.time(),
    }

    write(dir, sessions)
end

-- One session entry by id, or nil.
function M.get(dir, session_id)
    return read(dir)[session_id]
end

-- All entries keyed by session id.
function M.all(dir)
    return read(dir)
end

return M
