-- Session lifecycle: one headless nvim server inside an outpost, bound to
-- one canonical project path.

local transport = require "outpost.transport"

local M = {}

-- Render a per-session manifest: the metadata remote scan needs
-- (canonical path, endpoint, created) for one session.
function M.manifest_json(canonical_path, endpoint, created)
    return vim.json.encode {
        canonical_path = canonical_path,
        endpoint = endpoint,
        created = created,
    }
end

-- The per-session directory: socket, log, and manifest under
-- ~/.cache/outpost/run/<session-id>/.
function M.paths(session_id)
    local root = "$HOME/.cache/outpost/run/" .. session_id

    return {
        root = root,
        socket = root .. "/server.sock",
        log = root .. "/server.log",
        manifest = root .. "/manifest.json",
    }
end

-- Shell-quote a value for embedding in a remote POSIX sh command.
local function shell_quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

-- The remote health-probe script for one session.
function M.build_probe_command(session_id)
    local paths = M.paths(session_id)

    return string.format(
        [[
set -eu
NVIM="$HOME/.cache/outpost/install/current/bin/nvim"
SOCK="%s"
# `timeout` guards against a hung server, but the outpost's tooling is never
# a dependency (rule 8): use it when the host has it
TO=""
command -v timeout >/dev/null 2>&1 && TO="timeout 10"
if [ -S "$SOCK" ] && $TO "$NVIM" --server "$SOCK" --remote-expr 1 </dev/null >/dev/null 2>&1; then
    echo "live 1"
elif [ -e "%s" ]; then
    echo "dead 1"
else
    echo "dead 0"
fi
]],
        paths.socket,
        paths.manifest
    )
end

-- The remote start script for one session.
function M.build_start_command(session_id, canonical_path, endpoint)
    local paths = M.paths(session_id)
    local created = os.time()

    return string.format(
        [[
set -eu
umask 077
SESS="%s"
SOCK="%s"
LOG="%s"
NVIM="$HOME/.cache/outpost/install/current/bin/nvim"

# a half-installed outpost must fail loudly here, not as a mystery timeout
i=0
while [ ! -x "$NVIM" ]; do
    i=$((i+1))
    if [ "$i" -ge 10 ]; then
        echo 'outpost-session-start-failed: the outpost nvim binary is not executable'
        exit 1
    fi
    sleep 0.3
done

# the project directory must exist before the old session directory is
# touched: a failed start must not destroy the previous manifest (the
# lossy-state marker, ADR-0006)
cd %s
rm -rf "$SESS"
mkdir -p "$SESS"
chmod 700 "$SESS"
printf '%%s' %s > "%s"
export OUTPOST_SESSION=1
nohup "$NVIM" --headless --listen "$SOCK" >>"$LOG" 2>&1 </dev/null &
i=0
while [ ! -S "$SOCK" ]; do
    i=$((i+1))
    if [ "$i" -ge 100 ]; then
        echo 'outpost-session-start-failed: server socket never appeared (see server.log)'
        exit 1
    fi
    sleep 0.1
done
chmod 600 "$SOCK"
]],
        paths.root,
        paths.socket,
        paths.log,
        shell_quote(canonical_path),
        shell_quote(M.manifest_json(canonical_path, endpoint, created)),
        paths.manifest
    )
end

-- Ask the session server one expression over the probe pattern
-- (`nvim --server <socket> --remote-expr` over ssh). callback(out, err).
function M.query(endpoint, session_id, expr, opts, callback)
    opts = opts or {}

    local paths = M.paths(session_id)
    local command = string.format(
        '$HOME/.cache/outpost/install/current/bin/nvim --server "%s" --remote-expr %s </dev/null',
        paths.socket,
        shell_quote(expr)
    )

    transport.run(endpoint, command, opts.conn, function(code, out, err)
        if code ~= 0 then
            callback(nil, err or ("query failed with exit " .. code))
            return
        end

        callback(vim.trim(out), nil)
    end)
end

-- Health probe:
-- callback({ state = "live"|"dead", remains = bool }, err).
function M.probe(endpoint, session_id, conn, callback)
    transport.run(endpoint, M.build_probe_command(session_id), conn, function(code, out, err)
        if code ~= 0 then
            callback(nil, err or ("probe failed with exit " .. code))
            return
        end

        local state, remains = out:match "^(%S+) (%d+)"

        if not state then
            callback(nil, "unreadable probe output: " .. vim.trim(out))
            return
        end

        callback({ state = state, remains = remains == "1" }, nil)
    end)
end

-- Wait until the session answers the probe: callback(live, err). The start
-- script already waits for the socket file; this absorbs the last moments
-- before the RPC server answers.
local function wait_live(endpoint, session_id, conn, callback, tries)
    M.probe(endpoint, session_id, conn, function(state)
        if state and state.state == "live" then
            callback(true, nil)
            return
        end

        tries = tries - 1

        if tries <= 0 then
            callback(false, "session server did not answer the probe in time")
            return
        end

        vim.defer_fn(function()
            wait_live(endpoint, session_id, conn, callback, tries)
        end, 250)
    end)
end

-- Start the session server for a resolved identity
-- ({ session_id, canonical_path, endpoint }): fresh session directory, cwd
-- = the canonical path, OUTPOST_SESSION=1, private modes. callback(ok, err)
-- once the server answers the probe.
function M.start(resolved, opts, callback)
    opts = opts or {}

    local command = M.build_start_command(resolved.session_id, resolved.canonical_path, resolved.endpoint)

    transport.run(resolved.endpoint, command, opts.conn, function(code, out, err)
        if code ~= 0 then
            -- the failure marker goes to stdout; keep whichever side explains it
            local detail = vim.trim(err or "")

            if detail == "" then
                detail = vim.trim(out or "")
            end

            callback(false, "session start failed: " .. (detail ~= "" and detail or ("exit " .. code)))
            return
        end

        wait_live(resolved.endpoint, resolved.session_id, opts.conn, callback, 12)
    end)
end

return M
