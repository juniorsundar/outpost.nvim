-- Remote command assembly: the ssh/scp option sets and invocation
-- primitives used to reach an outpost.

local M = {}

local function options(conn, port_flag)
    conn = conn or {}

    local args = {}

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
function M.run(host, command, conn, callback)
    local argv = { "ssh" }

    vim.list_extend(argv, M.ssh_args(conn))
    table.insert(argv, host)
    table.insert(argv, command)

    vim.system(argv, { text = true }, function(result)
        vim.schedule(function()
            callback(result.code, result.stdout, result.stderr)
        end)
    end)
end

-- Upload a local file onto the outpost over scp. callback(ok, err).
function M.upload(host, local_path, remote_path, conn, callback)
    local argv = { "scp" }

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
