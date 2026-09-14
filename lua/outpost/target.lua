-- Target parsing: what the user types - `user@host:path`, host may be an
-- ssh-config alias.

local M = {}

local EXPECTED = "(expected user@host:path)"

-- Parse a typed target. Returns nil + a clear error on any malformed form.
function M.parse(input)
    local function reject()
        return nil, ("not a target: %s %s"):format(input, EXPECTED)
    end

    if type(input) ~= "string" then
        return reject()
    end

    local colon = input:find(":", 1, true)

    if not colon then
        return reject()
    end

    local user_host = input:sub(1, colon - 1)
    local path = input:sub(colon + 1)

    local at = user_host:find("@", 1, true)

    if not at then
        return reject()
    end

    local user = user_host:sub(1, at - 1)
    local host = user_host:sub(at + 1)

    if user == "" or host == "" or path == "" then
        return reject()
    end

    return {
        user = user,
        host = host,
        path = path,
    }
end

return M
