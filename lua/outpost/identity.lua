-- Identity: the `session id = sha256(instance_id + ":" + canonical_project_path)[:6]`.
-- The instance id is the outpost's UUID (minted on the outpost); the
-- canonical path is realpath'd on the remote. Neither endpoint nor typed
-- target takes part in identity.

local M = {}

function M.session_id(instance_id, canonical_path)
    local digest = vim.fn.sha256(instance_id .. ":" .. canonical_path)

    return digest:sub(1, 6)
end

return M
