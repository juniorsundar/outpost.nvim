-- Control plane orchestration: wires the user-facing flows - `up`'s
-- identity ladderand the update pipeline.

local M = {}

local dispatch = require "outpost.dispatch"
local release = require "outpost.release"
local up = require "outpost.up"

function M.up(target, opts)
    up.run(target, opts or {}, function() end)
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

                    vim.notify("outpost: " .. host .. " now on " .. tag)
                end)
            end)
        end)
    end)
end

function M.setup()
    dispatch.setup {
        up = M.up,
        update = M.update,
    }
end

return M
