-- Offline spec for the update surface's progress view: every collaborator
-- is stubbed at the module seam, the view is a recording handle.

local helpers = require "outpost.view_helpers"

local config = require "outpost.config"
local init = require "outpost"
local release = require "outpost.release"

local HOST = "outpost@127.0.0.1"
local TAG = "v0.11.0"

local recording_view = helpers.recording_view
local timeline = helpers.timeline
local opened = helpers.opened
local pretend_ui = helpers.pretend_ui

describe("update progress view", function()
    local stubs
    local view
    local reported
    local real_notify

    local function revert_all()
        for _, s in ipairs(stubs or {}) do
            s:revert()
        end

        stubs = {}
    end

    local function replace(module, name, impl)
        helpers.replace(stubs, module, name, impl)
    end

    -- Drive the update command with the pipeline's collaborators stubbed; `state`
    -- tunes the responses, and the install seam asserts it rode the invocation's handle.
    local function run(state)
        stubs = {}
        view = recording_view()
        reported = {}

        replace(release, "resolve_remote", function(_, _, callback)
            table.insert(view.events, { kind = "call", name = "release.resolve_remote" })

            if state.resolve_err then
                callback(nil, state.resolve_err)
                return
            end

            callback({ platform = "linux-x86_64", home = "/home/outpost" }, nil)
        end)

        replace(release, "latest_tag", function(callback)
            table.insert(view.events, { kind = "call", name = "release.latest_tag" })

            if state.tag_err then
                callback(nil, state.tag_err)
                return
            end

            callback(TAG, nil)
        end)

        replace(release, "remote_version", function(_, _, callback)
            table.insert(view.events, { kind = "call", name = "release.remote_version" })
            callback(state.installed, nil)
        end)

        replace(release, "install", function(_, _, _, opts, callback)
            table.insert(view.events, { kind = "call", name = "release.install" })

            assert.equal(view, opts.view, "the install pipeline must ride the update's own view")

            -- where the real pipeline announces its entry phase
            opts.view:open()
            opts.view:phase "downloading the bundle"

            if state.install_err then
                callback(false, state.install_err)
                return
            end

            callback(true, nil)
        end)

        init.update(HOST, { view = view })

        revert_all()
    end

    before_each(function()
        stubs = {}
        real_notify = vim.notify

        vim.notify = function(msg, level)
            table.insert(reported, { msg = msg, level = level })
        end
    end)

    after_each(function()
        vim.notify = real_notify
        revert_all()
    end)

    it(
        "opens the view at the install pipeline's entry and emits its phases through the invocation's own handle",
        function()
            run { installed = "v0.10.0" }

            assert.are.same({
                "release.resolve_remote",
                "release.latest_tag",
                "release.remote_version",
                "release.install",
                "open",
                "phase: downloading the bundle",
                "succeed",
            }, timeline(view))
            assert.truthy(opened(view))
        end
    )

    it("auto-closes on success with the existing notifications unchanged", function()
        run { installed = "v0.10.0" }

        assert.are.same(
            {
                ("outpost: updating %s (v0.10.0 -> %s)"):format(HOST, TAG),
                ("outpost: %s now on %s"):format(HOST, TAG),
            },
            vim.tbl_map(function(entry)
                return entry.msg
            end, reported)
        )
    end)

    it("announces a fresh install and closes the same way", function()
        run { installed = nil }

        assert.truthy(reported[1].msg:find("installing Neovim " .. TAG, 1, true))
        assert.equal("succeed", view.events[#view.events].kind)
    end)

    it("keeps the view focused with the full error output on install failure", function()
        run { installed = "v0.10.0", install_err = "remote install failed: the extracted tree is not runnable" }

        assert.are.same({
            "release.resolve_remote",
            "release.latest_tag",
            "release.remote_version",
            "release.install",
            "open",
            "phase: downloading the bundle",
            "stream",
            "fail",
        }, timeline(view))

        local stream = view.events[#view.events - 1]

        assert.equal("stderr", stream.source)
        assert.truthy(stream.chunk:find("the extracted tree is not runnable", 1, true))
        assert.equal(vim.log.levels.ERROR, reported[#reported].level)
    end)

    it("opens no window when identity resolution fails", function()
        run { resolve_err = "endpoint expansion failed" }

        assert.falsy(opened(view))
        assert.are.same({ "release.resolve_remote", "fail" }, timeline(view))
        assert.equal(vim.log.levels.ERROR, reported[1].level)
    end)

    it("winds the handle down when the latest tag cannot be resolved", function()
        run { tag_err = "failed to resolve latest release" }

        assert.are.same({ "release.resolve_remote", "release.latest_tag", "fail" }, timeline(view))
        assert.equal(vim.log.levels.ERROR, reported[1].level)
    end)

    it("stays silent when the outpost is already on the latest tag", function()
        run { installed = TAG }

        assert.falsy(opened(view))
        assert.are.same({
            "release.resolve_remote",
            "release.latest_tag",
            "release.remote_version",
            "succeed",
        }, timeline(view))
        assert.truthy(reported[1].msg:find("already on " .. TAG, 1, true))
    end)

    it("backs one invocation with exactly one handle from the injected factory", function()
        stubs = {}
        view = recording_view()
        reported = {}

        local handles = {}

        replace(release, "resolve_remote", function(_, _, callback)
            callback({ platform = "linux-x86_64", home = "/home/outpost" }, nil)
        end)
        replace(release, "latest_tag", function(callback)
            callback(TAG, nil)
        end)
        replace(release, "remote_version", function(_, _, callback)
            callback("v0.10.0", nil)
        end)
        replace(release, "install", function(_, _, _, opts, callback)
            assert.equal(handles[1], opts.view, "the factory's handle must reach the install pipeline")
            callback(true, nil)
        end)

        init.update(HOST, {
            progress = function()
                local handle = recording_view()

                table.insert(handles, handle)

                return handle
            end,
        })

        revert_all()

        assert.equal(1, #handles)
        assert.equal("succeed", handles[1].events[#handles[1].events].kind)
        assert.truthy(reported[#reported].msg:find("now on " .. TAG, 1, true))
    end)

    it("degrades to the real handle's lifecycle offline - no window, no debris", function()
        local ui = pretend_ui()

        stubs = {}
        view = recording_view()
        reported = {}

        replace(release, "resolve_remote", function(_, _, callback)
            callback({ platform = "linux-x86_64", home = "/home/outpost" }, nil)
        end)
        replace(release, "latest_tag", function(callback)
            callback(TAG, nil)
        end)
        replace(release, "remote_version", function(_, _, callback)
            callback(TAG, nil)
        end)

        local windows_before = #vim.api.nvim_list_wins()
        local buffers_before = #vim.api.nvim_list_bufs()

        init.update(HOST, {})

        revert_all()
        ui:revert()

        assert.equal(windows_before, #vim.api.nvim_list_wins(), "a silent update must not flicker a window")
        assert.equal(buffers_before, #vim.api.nvim_list_bufs(), "success leaves no buffer debris")
    end)

    it("runs the whole pipeline without a window when setup disabled the view", function()
        config.setup { progress = false }

        local ui = pretend_ui()

        stubs = {}
        reported = {}

        replace(release, "resolve_remote", function(_, _, callback)
            callback({ platform = "linux-x86_64", home = "/home/outpost" }, nil)
        end)
        replace(release, "latest_tag", function(callback)
            callback(TAG, nil)
        end)
        replace(release, "remote_version", function(_, _, callback)
            callback("v0.10.0", nil)
        end)

        local windows_before = #vim.api.nvim_list_wins()
        local buffers_before = #vim.api.nvim_list_bufs()

        replace(release, "install", function(_, _, _, opts, callback)
            opts.view:open()
            opts.view:phase "downloading the bundle"
            -- mid-flight: success has not yet auto-closed anything
            assert.equal(windows_before, #vim.api.nvim_list_wins(), "a disabled view must never open a window")
            callback(true, nil)
        end)

        init.update(HOST, {})

        revert_all()
        ui:revert()
        config.setup {}

        assert.equal(windows_before, #vim.api.nvim_list_wins(), "a disabled view must leave no window behind")
        assert.equal(buffers_before, #vim.api.nvim_list_bufs(), "success leaves no buffer debris")
        assert.are.same(
            {
                ("outpost: updating %s (v0.10.0 -> %s)"):format(HOST, TAG),
                ("outpost: %s now on %s"):format(HOST, TAG),
            },
            vim.tbl_map(function(entry)
                return entry.msg
            end, reported)
        )
    end)
end)
