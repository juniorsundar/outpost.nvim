-- Remote command assembly: the ssh/scp option sets and invocation
-- primitives used to reach an outpost.

local M = {}

-- The per-endpoint control socket path for multiplexed connections. ssh
-- expands %C to a hash of the endpoint, so one path serves every host.
function M.mux_path()
    return vim.fs.joinpath(vim.fn.stdpath "cache", "outpost", "mux", "%C")
end

-- ssh will not create the mux socket directory, and would silently fall back
-- to an unmuxed (re-prompting) connection.
function M.ensure_mux_dir(conn)
    if not (conn and conn.mux) then
        return
    end

    vim.fn.mkdir(vim.fs.dirname(conn.mux_path or M.mux_path()), "p")
end

local function mux_args(conn)
    if not conn.mux then
        return {}
    end

    return {
        "-o",
        "ControlMaster=auto",
        "-o",
        "ControlPath=" .. (conn.mux_path or M.mux_path()),
        "-o",
        "ControlPersist=10m",
    }
end

local function options(conn, port_flag)
    conn = conn or {}

    local args = {}

    vim.list_extend(args, mux_args(conn))

    if conn.port then
        vim.list_extend(args, { port_flag, conn.port })
    end

    if conn.key then
        vim.list_extend(args, { "-i", conn.key })
    end

    if conn.port or conn.key or conn.known_hosts then
        vim.list_extend(args, { "-o", "StrictHostKeyChecking=accept-new" })

        if conn.known_hosts then
            vim.list_extend(args, { "-o", "UserKnownHostsFile=" .. conn.known_hosts })
        end

        vim.list_extend(args, { "-o", "BatchMode=yes", "-o", "ConnectTimeout=2" })
    end

    return args
end

function M.ssh_args(conn)
    return options(conn, "-p")
end

function M.scp_args(conn)
    return options(conn, "-P")
end

-- Run a command on the outpost over ssh. callback(code, stdout, stderr).
-- The command is fed to a POSIX `sh` on stdin, so the remote user's login
-- shell (bash, zsh, fish, ...) never parses it and its dialect cannot matter.
function M.run(host, command, conn, callback)
    local argv = { "ssh" }

    M.ensure_mux_dir(conn)
    vim.list_extend(argv, M.ssh_args(conn))
    table.insert(argv, host)
    table.insert(argv, "sh -s")

    vim.system(argv, { stdin = command, text = true }, function(result)
        vim.schedule(function()
            callback(result.code, result.stdout, result.stderr)
        end)
    end)
end

-- Upload a local file onto the outpost over scp. callback(ok, err).
function M.upload(host, local_path, remote_path, conn, callback)
    local argv = { "scp" }

    M.ensure_mux_dir(conn)
    vim.list_extend(argv, M.scp_args(conn))
    table.insert(argv, local_path)
    table.insert(argv, host .. ":" .. remote_path)

    vim.system(argv, { text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                callback(false, result.stderr or "upload failed")
                return
            end

            callback(true, nil)
        end)
    end)
end

return M
