-- Endpoint expansion: the target after local ssh expansion - resolved
-- `user@hostname`, transport-only.

local M = {}

-- Build the endpoint from recorded `ssh -G` output: the resolved user and
-- hostname among the emitted fields. The port is deliberately dropped -
-- endpoints carry no port.
function M.from_ssh_g(output)
    local user, hostname

    for line in output:gmatch "[^\n]+" do
        local key, value = line:match "^(%S+)%s+(.+)$"

        if key == "user" and user == nil then
            user = value
        elseif key == "hostname" and hostname == nil then
            hostname = value
        end
    end

    return user .. "@" .. hostname
end

-- The base's own account. Nil when the local user or hostname is unknown,
-- in which case no endpoint can be recognised as the base.
function M.base()
    local passwd = vim.uv.os_get_passwd()
    local user = (passwd and passwd.username) or vim.env.USER
    local hostname = vim.uv.os_gethostname()

    if not user or not hostname then
        return nil
    end

    return user .. "@" .. hostname
end

-- Whether a resolved endpoint names the base's own account.
function M.is_base(resolved, base)
    base = base or M.base()

    return base ~= nil and resolved == base
end

return M
