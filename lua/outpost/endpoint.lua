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

return M
