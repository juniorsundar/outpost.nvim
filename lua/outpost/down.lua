-- `:Outpost down`: destroy an entire outpost - kill every live session
-- first, then remove everything under ~/.cache/outpost/ on that host.

local present = require "outpost.present"
local registry = require "outpost.registry"
local scan = require "outpost.scan"
local transport = require "outpost.transport"

local M = {}

-- Kill every session's recorded pid (tolerating one already gone, or one
-- with no pidfile at all), then remove the whole outpost cache directory.
function M.build_teardown_command()
    return [[
set -eu
RUN="$HOME/.cache/outpost/run"
if [ -d "$RUN" ]; then
    for dir in "$RUN"/*/; do
        [ -d "$dir" ] || continue
        PID="$(cat "$dir/server.pid" 2>/dev/null || true)"
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            kill -TERM "$PID" 2>/dev/null || true
        fi
    done
fi
rm -rf "$HOME/.cache/outpost"
]]
end

-- Remove the whole outpost. callback(ok, err).
function M.teardown(endpoint, conn, callback)
    transport.run(endpoint, M.build_teardown_command(), conn, function(code, _, err)
        if code ~= 0 then
            callback(false, err or ("teardown failed with exit " .. code))
            return
        end

        callback(true, nil)
    end)
end

-- Every registered session id for a host, dropped ahead of a successful
-- teardown (registration is meaningless once the outpost is gone).
local function registered_sessions(dir, host)
    local ids = {}

    for session_id, entry in pairs(registry.all(dir)) do
        entry.session_id = session_id

        if registry.host_of(entry) == host then
            table.insert(ids, session_id)
        end
    end

    return ids
end

-- The full `down` flow: resolve the host's endpoint, count its sessions,
-- confirm (unless banged), tear down.
function M.run(host, opts)
    opts = opts or {}

    local function fail(err)
        vim.notify("outpost: " .. err, vim.log.levels.ERROR)
    end

    local dir = registry.dir(opts.registry_dir)
    local ids = registered_sessions(dir, host)
    local entries = registry.all(dir)

    -- no expander: an unregistered host tears down as itself
    registry.resolve_endpoint(host, opts, entries, nil, function(endpoint)
        local scanner = opts.scan or scan.host

        scanner(endpoint, opts.conn, function(scanned, scan_err)
            local count = scanned and #scanned or #ids

            if not scanned and scan_err then
                -- the host could still be reachable for the teardown itself;
                -- a failed count is not a reason to refuse
                count = #ids
            end

            local noun = count == 1 and "session" or "sessions"

            present.ask(
                ("destroy the outpost at %s? this removes %d %s and cannot be undone"):format(host, count, noun),
                opts,
                function(ok)
                    if not ok then
                        return
                    end

                    M.teardown(endpoint, opts.conn, function(torn_down, teardown_err)
                        if not torn_down then
                            fail(teardown_err)
                            return
                        end

                        for _, session_id in ipairs(ids) do
                            registry.remove(dir, session_id)
                        end

                        vim.notify(("outpost: destroyed the outpost at %s"):format(host))
                    end)
                end
            )
        end)
    end)
end

return M
