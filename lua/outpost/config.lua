-- Setup-time configuration: currently, which hosts should have their ssh
-- connections multiplexed.

local M = {}

local config = { hosts = {} }

function M.setup(opts)
    config = vim.tbl_deep_extend("force", { hosts = {} }, opts or {})
end

-- Whether the host (as typed) is configured for ssh multiplexing.
function M.mux(host)
    local entry = host and config.hosts[host]

    return entry ~= nil and entry.mux == true or false
end

-- Connection details for a host: the caller's details plus multiplexing when
-- the host is configured for it.
function M.conn(host, base)
    base = vim.tbl_extend("force", {}, base or {})

    if M.mux(host) then
        base.mux = true
    end

    return base
end

return M
