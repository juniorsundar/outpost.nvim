-- Setup-time configuration: which hosts should opt out of ssh multiplexing,
-- the user's extra sync exclusion patterns, and the askpass bridge override.

local M = {}

local config = { hosts = {}, sync = { exclude = {} }, askpass = nil }

function M.setup(opts)
    config = vim.tbl_deep_extend("force", { hosts = {}, sync = { exclude = {} }, askpass = nil }, opts or {})
end

-- The askpass bridge override: true forces it on, false forces it off, nil
-- leaves it to UI detection.
function M.askpass()
    return config.askpass
end

-- Whether the host (as typed) is configured for ssh multiplexing.
function M.mux(host)
    local entry = host and config.hosts[host]

    return not (entry and entry.mux == false)
end

-- Connection details for a host: the caller's details plus multiplexing when
-- the host is configured for it.
function M.conn(host, base)
    base = vim.tbl_extend("force", {}, base or {})

    base.mux = M.mux(host)

    return base
end

-- The user's appended sync exclusion patterns, relative to each synced
-- root. Anything that is not a non-empty string is dropped rather than
-- failing setup.
function M.sync_exclude()
    local sync = type(config.sync) == "table" and config.sync or {}
    local excludes = type(sync.exclude) == "table" and sync.exclude or {}
    local patterns = {}

    for _, pattern in ipairs(excludes) do
        if type(pattern) == "string" and pattern ~= "" then
            table.insert(patterns, pattern)
        end
    end

    return patterns
end

return M
