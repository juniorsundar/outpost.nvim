-- Control plane orchestration: the probe/update flows, and the session
-- connect machinery (server start, tunnel, RPC) that later tickets re-home.

local M = {}

local dispatch = require "outpost.dispatch"
local release = require "outpost.release"

local tunnels = {}

local function start_remote_server(host, callback)
    local command = [[
SOCKET="$HOME/.cache/outpost/run/nvim.sock"
NVIM="$HOME/.cache/outpost/install/current/bin/nvim"

mkdir -p "$HOME/.cache/outpost/run"

if [ -S "$SOCKET" ] && "$NVIM" --server "$SOCKET" --remote-expr '1' >/dev/null 2>&1; then
    exit 0
fi

rm -f "$SOCKET"

nohup "$NVIM" \
  --headless \
  --listen "$SOCKET" \
  >"$HOME/.cache/outpost/run/nvim.log" \
  2>&1 </dev/null &

sleep 1

test -S "$SOCKET"
]]

    vim.system({
        "ssh",
        host,
        command,
    }, { text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                callback(false, result.stderr or "failed to start remote Neovim")
                return
            end

            callback(true, nil)
        end)
    end)
end

local function start_tunnel(host, remote_home, callback)
    local existing = tunnels[host]

    if existing then
        existing.process:kill(15)
        tunnels[host] = nil
    end

    local local_socket = vim.fs.joinpath(vim.fn.stdpath "cache", "outpost", "run", "nvim.sock")

    vim.fn.mkdir(vim.fs.dirname(local_socket), "p")
    vim.fn.delete(local_socket)

    local remote_socket = remote_home .. "/.cache/outpost/run/nvim.sock"

    local process = vim.system {
        "ssh",
        "-N",
        "-o",
        "ExitOnForwardFailure=yes",
        "-L",
        local_socket .. ":" .. remote_socket,
        host,
    }

    vim.defer_fn(function()
        if vim.uv.fs_stat(local_socket) then
            tunnels[host] = {
                process = process,
                socket = local_socket,
            }

            callback(true, tunnels[host])
        else
            process:kill(15)
            callback(false, "SSH tunnel did not create local socket")
        end
    end, 1000)
end

local function connect_rpc(socket)
    local channel = vim.fn.sockconnect("pipe", socket, { rpc = true })

    if channel <= 0 then
        return nil, "failed to connect to remote Neovim RPC"
    end

    return channel, nil
end

local function connect_remote(host, remote_home)
    start_remote_server(host, function(started, start_err)
        if not started then
            vim.notify(start_err, vim.log.levels.ERROR)
            return
        end

        start_tunnel(host, remote_home, function(ok, tunnel)
            if not ok then
                vim.notify(tunnel, vim.log.levels.ERROR)
                return
            end

            local channel, rpc_err = connect_rpc(tunnel.socket)

            if not channel then
                vim.notify(rpc_err, vim.log.levels.ERROR)
                return
            end

            local version = vim.rpcrequest(
                channel,
                "nvim_exec_lua",
                [[
                    local v = vim.version()
                    return string.format(
                        "%d.%d.%d%s",
                        v.major,
                        v.minor,
                        v.patch,
                        v.prerelease and "-dev" or ""
                    )
                ]],
                {}
            )

            vim.notify("remote Neovim: " .. version)
        end)
    end)
end

function M.probe(host)
    release.resolve_remote(host, {}, function(remote, err)
        if not remote then
            vim.notify(err, vim.log.levels.ERROR)
            return
        end

        release.latest_tag(function(tag, tag_err)
            if not tag then
                vim.notify(tag_err, vim.log.levels.ERROR)
                return
            end

            release.remote_version(host, {}, function(installed)
                if installed == tag then
                    connect_remote(host, remote.home)
                    return
                end

                if installed then
                    vim.notify(
                        string.format(
                            "outpost: update available (%s -> %s). Run :OutpostUpdate %s",
                            installed,
                            tag,
                            host
                        ),
                        vim.log.levels.WARN
                    )
                    return
                end

                vim.notify("outpost: installing Neovim " .. tag .. " on " .. host)
                release.install(host, remote.platform, tag, {}, function(ok, install_err)
                    if not ok then
                        vim.notify(install_err, vim.log.levels.ERROR)
                        return
                    end

                    connect_remote(host, remote.home)
                end)
            end)
        end)
    end)
end

function M.update(host)
    release.resolve_remote(host, {}, function(remote, err)
        if not remote then
            vim.notify(err, vim.log.levels.ERROR)
            return
        end

        release.latest_tag(function(tag, tag_err)
            if not tag then
                vim.notify(tag_err, vim.log.levels.ERROR)
                return
            end

            release.remote_version(host, {}, function(installed)
                if installed == tag then
                    vim.notify("outpost: " .. host .. " already on " .. tag)
                    connect_remote(host, remote.home)
                    return
                end

                if installed then
                    vim.notify(string.format("outpost: updating %s (%s -> %s)", host, installed, tag))
                else
                    vim.notify("outpost: installing Neovim " .. tag .. " on " .. host)
                end

                release.install(host, remote.platform, tag, {}, function(ok, install_err)
                    if not ok then
                        vim.notify(install_err, vim.log.levels.ERROR)
                        return
                    end

                    connect_remote(host, remote.home)
                end)
            end)
        end)
    end)
end

function M.setup()
    dispatch.setup {
        probe = M.probe,
        update = M.update,
    }
end

return M
