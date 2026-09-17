-- The bare-picker re-entries (`up`, `sync` with no target) open the progress
-- view exactly like the typed invocations: one handle, driven to its outcome.

local helpers = require "outpost.view_helpers"

local config = require "outpost.config"
local init = require "outpost"
local registry = require "outpost.registry"
local sync = require "outpost.sync"

local recording_view = helpers.recording_view

describe("bare sync picker re-entry", function()
    local stubs
    local reported
    local real_notify
    local registry_dir

    local function replace(module, name, impl)
        helpers.replace(stubs, module, name, impl)
    end

    before_each(function()
        stubs = {}
        reported = {}

        real_notify = vim.notify

        vim.notify = function(msg, level)
            table.insert(reported, { msg = msg, level = level })
        end

        replace(vim.ui, "select", function(items, _, callback)
            callback(items[1])
        end)

        registry_dir = vim.fn.tempname()

        vim.fn.mkdir(registry_dir, "p")
        registry.record(registry_dir, {
            session_id = "00ac56",
            endpoint = "outpost@10.0.0.4",
            canonical_path = "/srv/proj",
            typed_target = "outpost@box:~/proj",
        })
    end)

    after_each(function()
        vim.notify = real_notify

        for _, s in ipairs(stubs) do
            s:revert()
        end

        config.setup {}
        vim.fn.delete(registry_dir, "rf")
    end)

    it("runs the picked host through the same view-backed surface", function()
        local views = {}
        local seen_endpoint

        replace(sync, "sync", function(endpoint, _, callback)
            seen_endpoint = endpoint
            callback({ stats = { files = 1, bytes = 10 } }, nil)
        end)

        init.sync("", false, {
            registry_dir = registry_dir,
            live_count = function(_, _, callback)
                callback(0)
            end,
            progress = function()
                local view = recording_view()

                table.insert(views, view)

                return view
            end,
        })

        assert.equal(1, #views, "one invocation, one handle")
        assert.equal("outpost@10.0.0.4", seen_endpoint)
        assert.equal("succeed", views[1].events[#views[1].events].kind)
        assert.equal(2, #reported)
        assert.truthy(reported[1].msg:find("syncing box", 1, true))
        assert.truthy(reported[2].msg:find("synced box", 1, true))
    end)

    it("drives the view to the failure outcome when the picked sync fails", function()
        replace(sync, "sync", function(_, _, callback)
            callback(nil, "rsync failed for the config tree (exit 23)")
        end)

        local views = {}

        init.sync("", false, {
            registry_dir = registry_dir,
            progress = function()
                local view = recording_view()

                table.insert(views, view)

                return view
            end,
        })

        assert.equal(1, #views)
        assert.equal("fail", views[1].events[#views[1].events].kind)
        assert.equal(vim.log.levels.ERROR, reported[#reported].level)
    end)
end)

describe("bare up picker re-entry", function()
    local attach = require "outpost.attach"
    local client = require "outpost.client"
    local present = require "outpost.present"
    local release = require "outpost.release"
    local session = require "outpost.session"
    local up = require "outpost.up"

    local stubs
    local reported
    local real_notify
    local registry_dir

    local RESOLVED = {
        target = { user = "outpost", host = "box", path = "~/proj" },
        endpoint = "outpost@10.0.0.4",
        instance_id = "0f0f0f0f-0000-0000-0000-000000000000",
        canonical_path = "/srv/proj",
        home = "/home/outpost",
        session_id = "a1b2c3",
    }

    local function replace(module, name, impl)
        helpers.replace(stubs, module, name, impl)
    end

    before_each(function()
        stubs = {}
        reported = {}

        real_notify = vim.notify

        vim.notify = function(msg, level)
            table.insert(reported, { msg = msg, level = level })
        end

        replace(vim.ui, "select", function(items, _, callback)
            callback(items[1])
        end)

        registry_dir = vim.fn.tempname()

        vim.fn.mkdir(registry_dir, "p")
        registry.record(registry_dir, {
            session_id = "00ac56",
            endpoint = "outpost@10.0.0.4",
            canonical_path = "/srv/proj",
            typed_target = "outpost@box:~/proj",
        })
    end)

    after_each(function()
        vim.notify = real_notify

        for _, s in ipairs(stubs) do
            s:revert()
        end

        config.setup {}
        vim.fn.delete(registry_dir, "rf")
    end)

    it("runs the picked session through the same view-backed ladder", function()
        -- the picker probes registry sessions for liveness
        replace(session, "probe", function(_, _, _, callback)
            callback({ state = "live", remains = false }, nil)
        end)
        replace(up, "resolve", function(_, _, callback)
            callback(RESOLVED, nil)
        end)
        replace(release, "usable_install", function(_, _, callback)
            callback "v0.2.0"
        end)
        replace(session, "takeover", function(_, _, _, callback)
            callback(0, nil)
        end)
        replace(client, "ensure", function(_, _, callback)
            callback("/tmp/pinned-client", nil)
        end)
        replace(attach, "prepare", function()
            return "/tmp/attach.sh"
        end)

        local views = {}
        local shown

        replace(present, "show", function(command)
            shown = command
        end)

        init.up("", {
            registry_dir = registry_dir,
            progress = function()
                local view = recording_view()

                table.insert(views, view)

                return view
            end,
        })

        assert.equal(1, #views, "one invocation, one handle")
        assert.equal("succeed", views[1].events[#views[1].events].kind)
        assert.truthy(shown, "the attach handout follows as on the typed path")
        assert.truthy(reported[1].msg:find("already live", 1, true))
    end)
end)
