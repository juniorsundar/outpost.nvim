-- Control plane orchestration: wires the user-facing flows - `up`'s
-- identity ladder and the update pipeline.

local M = {}

local complete = require "outpost.complete"
local config = require "outpost.config"
local dispatch = require "outpost.dispatch"
local picker = require "outpost.picker"
local present = require "outpost.present"
local release = require "outpost.release"
local target = require "outpost.target"
local up = require "outpost.up"

function M.up(target_str, opts)
    opts = opts or {}

    if target_str == nil or vim.trim(target_str) == "" then
        picker.pick(opts, function(chosen)
            M.up(chosen, opts)
        end)
        return
    end

    local parsed = target.parse(target_str)

    opts.conn = config.conn(parsed and parsed.host, opts.conn)

    up.run(target_str, opts, function(result)
        if result and result.command then
            present.show(result.command)
        end
    end)
end

function M.update(host)
    local conn = config.conn(host)

    release.resolve_remote(host, { conn = conn }, function(remote, err)
        if not remote then
            vim.notify(err, vim.log.levels.ERROR)
            return
        end

        release.latest_tag(function(tag, tag_err)
            if not tag then
                vim.notify(tag_err, vim.log.levels.ERROR)
                return
            end

            release.remote_version(host, { conn = conn }, function(installed)
                if installed == tag then
                    vim.notify("outpost: " .. host .. " already on " .. tag)
                    return
                end

                if installed then
                    vim.notify(string.format("outpost: updating %s (%s -> %s)", host, installed, tag))
                else
                    vim.notify("outpost: installing Neovim " .. tag .. " on " .. host)
                end

                release.install(host, remote.platform, tag, { conn = conn }, function(ok, install_err)
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

function M.setup(opts)
    config.setup(opts)
    dispatch.setup {
        up = {
            run = M.up,
            complete = function(arglead)
                return complete.up(arglead, {})
            end,
        },
        update = {
            run = M.update,
            complete = function(arglead)
                return complete.hosts(arglead, {})
            end,
        },
    }
end

return M
