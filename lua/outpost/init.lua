-- Control plane orchestration: wires the user-facing flows - `up`'s
-- identity ladder, the lifecycle trio (list/stop/down), and the update
-- pipeline.

local M = {}

local complete = require "outpost.complete"
local config = require "outpost.config"
local dispatch = require "outpost.dispatch"
local down = require "outpost.down"
local list = require "outpost.list"
local picker = require "outpost.picker"
local present = require "outpost.present"
local release = require "outpost.release"
local stop = require "outpost.stop"
local sync = require "outpost.sync"
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

function M.list(host, _bang, opts)
    opts = opts or {}

    list.run(host and vim.trim(host) ~= "" and host or nil, opts)
end

function M.stop(target_str, bang, opts)
    opts = vim.tbl_extend("force", { bang = bang }, opts or {})

    if target_str == nil or vim.trim(target_str) == "" then
        picker.pick_stop(opts, function(session_id)
            M.stop(session_id, bang, opts)
        end)
        return
    end

    local parsed = not stop.is_session_id(target_str) and target.parse(target_str) or nil

    opts.conn = config.conn(parsed and parsed.host, opts.conn)

    stop.run(target_str, opts)
end

function M.down(host, bang, opts)
    opts = vim.tbl_extend("force", { bang = bang }, opts or {})

    if host == nil or vim.trim(host) == "" then
        picker.pick_down(opts, function(chosen)
            M.down(chosen, bang, opts)
        end)
        return
    end

    opts.conn = config.conn(host, opts.conn)

    down.run(host, opts)
end

function M.sync(host, bang, opts)
    opts = vim.tbl_extend("force", { bang = bang }, opts or {})

    if host == nil or vim.trim(host) == "" then
        picker.pick_sync(opts, function(chosen)
            M.sync(chosen, bang, opts)
        end)
        return
    end

    opts.conn = config.conn(host, opts.conn)

    sync.run(host, opts)
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

-- Inside an outpost session (OUTPOST_SESSION comes from the start script),
-- the plugin registers nothing and ships only the OSC52 clipboard branch.
local function session_branch(opts)
    if opts.session == false then
        return
    end

    local osc52 = require "vim.ui.clipboard.osc52"

    vim.g.clipboard = {
        name = "OSC 52",
        copy = { ["+"] = osc52.copy "+", ["*"] = osc52.copy "*" },
        paste = { ["+"] = osc52.paste "+", ["*"] = osc52.paste "*" },
    }
end

function M.setup(opts)
    opts = opts or {}

    if vim.env.OUTPOST_SESSION == "1" then
        session_branch(opts)
        return
    end

    config.setup(opts)
    dispatch.setup {
        up = {
            run = function(target_str)
                M.up(target_str, {})
            end,
            complete = function(arglead)
                return complete.up(arglead, {})
            end,
        },
        list = {
            run = function(host, bang)
                M.list(host, bang, {})
            end,
            complete = function(arglead)
                return complete.hosts(arglead, {})
            end,
        },
        stop = {
            run = function(target_str, bang)
                M.stop(target_str, bang, {})
            end,
            complete = function(arglead)
                return complete.stop(arglead, {})
            end,
        },
        down = {
            run = function(host, bang)
                M.down(host, bang, {})
            end,
            complete = function(arglead)
                return complete.hosts(arglead, {})
            end,
        },
        update = {
            run = M.update,
            complete = function(arglead)
                return complete.hosts(arglead, {})
            end,
        },
        sync = {
            run = M.sync,
            complete = function(arglead)
                return complete.hosts(arglead, {})
            end,
        },
    }
end

return M
