-- `:Outpost stop`: kill one session, or tidy up after an already-dead one.
-- A typed target resolves through one of two independent paths: the short
-- form (session id) via a registry lookup only, the long form
-- (`user@host:path`) by re-running the identity ladder, exactly like `up`.

local confirm = require "outpost.confirm"
local registry = require "outpost.registry"
local session = require "outpost.session"
local up = require "outpost.up"

local M = {}

function M.is_session_id(value)
    return type(value) == "string" and value:match "^%x%x%x%x%x%x$" ~= nil
end

local function default_registry_dir()
    return vim.fs.joinpath(vim.fn.stdpath "data", "outpost")
end

-- Resolve a typed target to { session_id, endpoint, canonical_path }.
-- callback(resolved, err).
function M.resolve(target_str, opts, callback)
    opts = opts or {}

    if M.is_session_id(target_str) then
        local dir = opts.registry_dir or default_registry_dir()
        local entry = registry.get(dir, target_str)

        if not entry then
            callback(nil, ("unknown session id: %s - run :Outpost list"):format(target_str))
            return
        end

        callback({
            session_id = target_str,
            endpoint = entry.endpoint,
            canonical_path = entry.canonical_path,
        }, nil)
        return
    end

    local resolver = opts.resolve_long or up.resolve

    resolver(target_str, opts, function(result, err)
        if not result then
            callback(nil, err)
            return
        end

        callback({
            session_id = result.session_id,
            endpoint = result.endpoint,
            canonical_path = result.canonical_path,
        }, nil)
    end)
end

-- Stop a resolved session: live is killed, dead is tidied, unreachable
-- (the probe itself could not run - ssh failed) errors without touching
-- anything. callback(ok, err).
local function act(resolved, opts, callback)
    session.probe(resolved.endpoint, resolved.session_id, opts.conn, function(state, probe_err)
        if not state then
            callback(false, ("can't reach %s, nothing stopped"):format(resolved.endpoint))
            return
        end

        confirm.ask(("stop session %s?"):format(resolved.session_id), opts, function(ok)
            if not ok then
                callback(false, "cancelled")
                return
            end

            session.stop(resolved.endpoint, resolved.session_id, opts.conn, function(stopped, stop_err)
                if not stopped then
                    callback(false, stop_err)
                    return
                end

                local dir = opts.registry_dir or default_registry_dir()

                registry.remove(dir, resolved.session_id)
                callback(true, nil)
            end)
        end)
    end)
end

-- The full `stop` flow: resolve, probe/classify, confirm (unless banged),
-- act.
function M.run(target_str, opts)
    opts = opts or {}

    local function fail(err)
        vim.notify("outpost: " .. err, vim.log.levels.ERROR)
    end

    M.resolve(target_str, opts, function(resolved, resolve_err)
        if not resolved then
            fail(resolve_err)
            return
        end

        act(resolved, opts, function(ok, err)
            if not ok then
                if err ~= "cancelled" then
                    fail(err)
                end
                return
            end

            vim.notify(("outpost: stopped session %s"):format(resolved.session_id))
        end)
    end)
end

return M
