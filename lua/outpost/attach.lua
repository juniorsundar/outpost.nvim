-- The attach script: a self-contained command that owns its ssh tunnel and
-- the pinned attach client's lifecycle, so attaching works from any terminal
-- whether or not the nvim that ran `up` survives.

local transport = require "outpost.transport"

local M = {}

local function default_dir()
    return vim.fs.joinpath(vim.fn.stdpath "cache", "outpost", "attach")
end

function M.dir(attach_dir)
    return attach_dir or default_dir()
end

-- The generated script, named by session id.
function M.path(session_id, attach_dir)
    return vim.fs.joinpath(M.dir(attach_dir), session_id .. ".sh")
end

-- The tunneled local socket the script binds for the session.
function M.socket_path(session_id, attach_dir)
    return vim.fs.joinpath(M.dir(attach_dir), session_id .. ".sock")
end

local function sh_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function ssh_command(identity)
    local argv = { "ssh" }

    -- the attach owns its tunnel: a multiplexed `-L` would be owned by the
    -- shared master, so the client exits at once and teardown cannot reach
    -- the forward
    local conn = vim.tbl_extend("force", {}, identity.conn or {})

    conn.mux = nil
    conn.mux_path = nil

    vim.list_extend(argv, transport.ssh_args(conn))
    vim.list_extend(argv, {
        "-o",
        "ControlMaster=no",
        "-o",
        "ExitOnForwardFailure=yes",
        "-N",
        "-L",
        identity.local_socket .. ":" .. identity.remote_socket,
        identity.endpoint,
    })

    local quoted = {}

    for _, token in ipairs(argv) do
        table.insert(quoted, sh_quote(token))
    end

    return table.concat(quoted, " ")
end

-- Render the script. Everything it needs is baked in at generation time:
-- the endpoint, both socket paths, the pinned client, and the same
-- non-interactive ssh options the control plane uses.
function M.render(identity)
    return ([[
#!/bin/sh
# outpost attach script - session %s
set -eu

SOCK=%s
CLIENT=%s

cleanup() {
    if [ -n "${TUNNEL:-}" ]; then kill "$TUNNEL" 2>/dev/null || true; fi
    rm -f "$SOCK"
}
trap cleanup EXIT INT TERM HUP

rm -f "$SOCK"
%s &
TUNNEL=$!

i=0
while [ ! -S "$SOCK" ]; do
    if ! kill -0 "$TUNNEL" 2>/dev/null; then
        echo 'outpost-attach-failed: the ssh tunnel exited before the local socket appeared' >&2
        exit 1
    fi
    i=$((i+1))
    if [ "$i" -ge 100 ]; then
        echo 'outpost-attach-failed: the tunneled socket never appeared' >&2
        exit 1
    fi
    sleep 0.1
done

# foreground: a background job would get /dev/null on stdin and exit at once
"$CLIENT" --remote-ui --server "$SOCK"
]]):format(identity.session_id, sh_quote(identity.local_socket), sh_quote(identity.client), ssh_command(identity))
end

-- Generate (or regenerate) the attach script for a session: sweep any
-- stale local socket, render with the session's socket path, write it, and
-- make it runnable. Returns the script path.
function M.prepare(identity, opts)
    opts = opts or {}

    local path = M.path(identity.session_id, opts.attach_dir)
    local local_socket = M.socket_path(identity.session_id, opts.attach_dir)

    vim.fn.mkdir(M.dir(opts.attach_dir), "p")
    vim.uv.fs_unlink(local_socket)

    local script = M.render(vim.tbl_extend("force", identity, { local_socket = local_socket }))

    vim.fn.writefile(vim.split((script:gsub("\n+$", "")), "\n"), path)
    vim.uv.fs_chmod(path, 493)

    return path
end

return M
