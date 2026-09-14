-- The `up` identity ladder: typed target → endpoint (local ssh -G,
-- transport-only) → one remote round trip that fetches-or-mints the outpost
-- instance id and resolves the canonical project path → the session id,
-- reported to the user.

local target = require "outpost.target"
local client = require "outpost.client"
local endpoint = require "outpost.endpoint"
local identity = require "outpost.identity"
local registry = require "outpost.registry"
local release = require "outpost.release"
local session = require "outpost.session"
local transport = require "outpost.transport"

local M = {}

local MISSING_PROJECT_MARKER = "outpost-missing-project"

local LADDER_COMMAND_TEMPLATE = [[
set -eu
P='%s'
case "$P" in
    "~") P="$HOME" ;;
    "~"/*) P="$HOME/${P#?}" ;;
esac
if [ ! -d "$P" ]; then
    echo "]] .. MISSING_PROJECT_MARKER .. [["
    exit 1
fi
CANON="$(realpath "$P")"
ID_FILE="$HOME/.cache/outpost/instance-id"
if [ ! -s "$ID_FILE" ]; then
    mkdir -p "$HOME/.cache/outpost"
    uuidgen >"$ID_FILE" 2>/dev/null ||
        od -An -N16 -tx1 /dev/urandom | tr -d ' \n' >"$ID_FILE"
fi
printf '%%s\n%%s\n' "$(cat "$ID_FILE")" "$CANON"
]]

local function shell_quote(path)
    return (path:gsub("'", "'\\''"))
end

-- Expand the target's host through the local ssh configuration into the
-- endpoint (`user@hostname`).
function M.expand(target_str, opts, callback)
    opts = opts or {}

    local parsed, parse_err = target.parse(target_str)

    if not parsed then
        callback(nil, parse_err)
        return
    end

    local argv = { "ssh" }

    vim.list_extend(argv, transport.ssh_args(opts.conn))

    if opts.ssh_config then
        vim.list_extend(argv, { "-F", opts.ssh_config })
    end

    table.insert(argv, "-G")
    table.insert(argv, parsed.user .. "@" .. parsed.host)

    vim.system(argv, { text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                callback(nil, "endpoint expansion failed: " .. (result.stderr or "ssh -G failed"))
                return
            end

            callback(endpoint.from_ssh_g(result.stdout), nil)
        end)
    end)
end

-- The full identity ladder: expand the endpoint, run the one remote round
-- trip, compute the session id.
-- callback(result, err) with
-- result = { target, endpoint, instance_id, canonical_path, session_id }.
function M.resolve(target_str, opts, callback)
    opts = opts or {}

    M.expand(target_str, opts, function(endpoint_str, expand_err)
        if not endpoint_str then
            callback(nil, expand_err)
            return
        end

        local parsed = target.parse(target_str)
        local command = LADDER_COMMAND_TEMPLATE:format(shell_quote(parsed.path))

        transport.run(endpoint_str, command, opts.conn, function(code, out, run_err)
            if code ~= 0 then
                if out:find(MISSING_PROJECT_MARKER, 1, true) then
                    callback(nil, ("no project directory on %s: %s"):format(endpoint_str, parsed.path))
                else
                    callback(nil, "remote ladder failed: " .. (run_err or ("exit " .. code)))
                end
                return
            end

            local lines = vim.split(vim.trim(out), "\n")
            local instance_id, canonical_path = lines[1], lines[2]

            callback({
                target = parsed,
                endpoint = endpoint_str,
                instance_id = instance_id,
                canonical_path = canonical_path,
                session_id = identity.session_id(instance_id, canonical_path),
            }, nil)
        end)
    end)
end

-- The full `up` ladder: resolve identity, then - idempotently - provision
-- the outpost and start its session, announcing each state to the user:
-- already-live, fresh start, or fresh-after-loss.
-- callback(result, err) with result = the resolve result plus the recorded
-- release tag and the pinned attach client path (plus platform/installed
-- when a start happened).
function M.run(target_str, opts, callback)
    opts = opts or {}

    local function fail(err)
        vim.notify("outpost: " .. err, vim.log.levels.ERROR)
        callback(nil, err)
    end

    M.resolve(target_str, opts, function(result, err)
        if not result then
            fail(err)
            return
        end

        local dir = opts.registry_dir or vim.fs.joinpath(vim.fn.stdpath "data", "outpost")

        local function register()
            registry.record(dir, {
                session_id = result.session_id,
                endpoint = result.endpoint,
                canonical_path = result.canonical_path,
                typed_target = target_str,
            })
        end

        -- Every path that leaves a live session ends here: ensure the pinned
        -- attach client, take over the UI slot, announce any detachment,
        -- register, and report. Takeover is unconditional - there is no
        -- refuse path.
        local function finish(message, level, extra)
            client.ensure(extra.tag, opts, function(client_path, client_err)
                if not client_path then
                    fail(client_err or "could not ensure the pinned attach client")
                    return
                end

                extra.client = client_path

                session.takeover(result.endpoint, result.session_id, opts, function(detached, takeover_err)
                    if not detached then
                        fail(takeover_err or "takeover failed")
                        return
                    end

                    if detached > 0 then
                        local noun = detached == 1 and "UI" or "UIs"

                        vim.notify(
                            ("outpost: detached %d existing %s from session %s"):format(
                                detached,
                                noun,
                                result.session_id
                            ),
                            vim.log.levels.WARN
                        )
                    end

                    register()
                    vim.notify(message, level)
                    callback(extra, nil)
                end)
            end)
        end

        session.probe(result.endpoint, result.session_id, opts.conn, function(state, probe_err)
            if not state then
                fail(probe_err or "health probe failed")
                return
            end

            -- A healthy session is idempotency: no provisioning, no second
            -- server, no download (the builds repo is never contacted). The
            -- recorded tag still has to be read so the pin can be ensured.
            if state.state == "live" then
                release.usable_install(result.endpoint, opts, function(tag)
                    if not tag then
                        fail "could not read the installed release tag"
                        return
                    end

                    finish(
                        ("outpost: session %s already live - %s:%s"):format(
                            result.session_id,
                            result.endpoint,
                            result.canonical_path
                        ),
                        vim.log.levels.INFO,
                        vim.tbl_extend("force", result, { tag = tag })
                    )
                end)

                return
            end

            release.ensure(result.endpoint, opts, function(ensured, ensure_err)
                if not ensured then
                    fail(ensure_err)
                    return
                end

                session.start(result, opts, function(started, start_err)
                    if not started then
                        fail(start_err)
                        return
                    end

                    local message
                    local level

                    -- Lossy by policy: when a previous session for this id
                    -- left a manifest behind, say so.
                    if state.remains then
                        message = ("outpost: started fresh session %s - %s:%s (previous session state was lost - session state is lossy by policy)"):format(
                            result.session_id,
                            result.endpoint,
                            result.canonical_path
                        )
                        level = vim.log.levels.WARN
                    else
                        message = ("outpost: started session %s - %s:%s"):format(
                            result.session_id,
                            result.endpoint,
                            result.canonical_path
                        )
                        level = vim.log.levels.INFO
                    end

                    finish(message, level, {
                        target = result.target,
                        endpoint = result.endpoint,
                        instance_id = result.instance_id,
                        canonical_path = result.canonical_path,
                        session_id = result.session_id,
                        platform = ensured.platform,
                        tag = ensured.tag,
                        installed = ensured.installed,
                    })
                end)
            end)
        end)
    end)
end

return M
