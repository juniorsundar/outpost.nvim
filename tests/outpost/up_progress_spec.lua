-- Offline unit spec for the progress gating of the `up` ladder: every
-- collaborator is stubbed at the module seam, the view is a recording handle.

local helpers = require "outpost.view_helpers"

local attach = require "outpost.attach"
local client = require "outpost.client"
local progress = require "outpost.progress"
local release = require "outpost.release"
local session = require "outpost.session"
local sync = require "outpost.sync"
local up = require "outpost.up"

local TARGET = "outpost@127.0.0.1:~/proj"

local RESOLVED = {
    target = { user = "outpost", host = "127.0.0.1", path = "~/proj" },
    endpoint = "outpost@127.0.0.1",
    instance_id = "0f0f0f0f-0000-0000-0000-000000000000",
    canonical_path = "/home/outpost/proj",
    home = "/home/outpost",
    session_id = "a1b2c3",
}

local recording_view = helpers.recording_view
local timeline = helpers.timeline
local opened = helpers.opened
local pretend_ui = helpers.pretend_ui

local function phases_of(view)
    local texts = {}

    for _, event in ipairs(view.events) do
        if event.kind == "phase" then
            table.insert(texts, event.text)
        end
    end

    return texts
end

local function contains(list, value)
    return vim.tbl_contains(list, value)
end

describe("up progress view", function()
    local stubs
    local view
    local reported
    local real_notify
    local registry_dir

    local function mark(name)
        table.insert(view.events, { kind = "call", name = name })
    end

    local function replace(module, name, impl)
        helpers.replace(stubs, module, name, impl)
    end

    local function revert_all()
        for _, s in ipairs(stubs) do
            s:revert()
        end

        stubs = {}
    end

    -- Drive up.run with the ladder's collaborators stubbed; `state` tunes
    -- the responses, and every view seam asserts it got the ladder's own handle.
    local function run(state)
        stubs = {}
        view = recording_view()

        replace(up, "resolve", function(_, _, callback)
            mark "up.resolve"

            if state.resolve_err then
                callback(nil, state.resolve_err)
                return
            end

            callback(RESOLVED, nil)
        end)

        replace(session, "probe", function(_, _, _, callback)
            mark "session.probe"
            callback(state.probe or { state = "dead", remains = false }, nil)
        end)

        replace(release, "usable_install", function(_, _, callback)
            mark "release.usable_install"
            callback "v0.2.0"
        end)

        replace(release, "ensure", function(_, opts, callback)
            mark "release.ensure"
            assert.equal(view, opts.view, "the install pipeline must ride the ladder's own view")
            callback({
                platform = "linux-x86_64",
                home = RESOLVED.home,
                tag = "v0.2.0",
                installed = state.installed == true,
            }, nil)
        end)

        replace(sync, "has_marker", function(_, _, callback)
            mark "sync.has_marker"
            callback(state.has_marker, state.marker_err)
        end)

        replace(sync, "sync", function(_, opts, callback)
            mark "sync.sync"
            assert.equal(view, opts.view, "the provisioning sync must ride the ladder's own view")

            if state.sync_err then
                callback(nil, state.sync_err)
                return
            end

            -- the engine emits its own phase lines into the ladder's view
            opts.view:phase "syncing the config tree"

            callback({ stats = { files = 1, bytes = 10 } }, nil)
        end)

        replace(session, "start", function(_, _, callback)
            mark "session.start"
            callback(true, nil)
        end)

        replace(session, "takeover", function(_, _, _, callback)
            mark "session.takeover"
            callback(0, nil)
        end)

        replace(client, "ensure", function(_, _, callback)
            mark "client.ensure"
            callback("/tmp/pinned-client", nil)
        end)

        replace(attach, "prepare", function()
            mark "attach.prepare"
            return "/tmp/attach.sh"
        end)

        local result, err

        up.run(TARGET, { registry_dir = registry_dir, view = view }, function(r, e)
            result, err = r, e
        end)

        revert_all()

        return result, err
    end

    before_each(function()
        stubs = {}
        view = recording_view()
        reported = {}

        real_notify = vim.notify

        vim.notify = function(msg, level)
            table.insert(reported, { msg = msg, level = level })
        end

        registry_dir = vim.fn.tempname() .. "-registry"
        vim.fn.mkdir(registry_dir, "p")
    end)

    after_each(function()
        vim.notify = real_notify
        revert_all()
        vim.fn.delete(registry_dir, "rf")
    end)

    it("opens no window for a live-session up - the fast path is completely silent", function()
        local result, err = run { probe = { state = "live", remains = false } }

        assert.truthy(result, err)
        assert.falsy(opened(view), "no window may ever appear for the fast path")
        assert.are.same({
            "phase: resolving the identity",
            "up.resolve",
            "phase: probing the session",
            "session.probe",
            "release.usable_install",
            "client.ensure",
            "session.takeover",
            "attach.prepare",
            "succeed",
        }, timeline(view))
        assert.truthy(reported[#reported].msg:find("already live", 1, true))
    end)

    it("announces each phase exactly when it starts on a cold ladder", function()
        local result, err = run { installed = true }

        assert.truthy(result, err)

        -- the sync stub emits its transfer's phase line through the shared
        -- view, exactly where the real engine does
        assert.are.same({
            "phase: resolving the identity",
            "up.resolve",
            "phase: probing the session",
            "session.probe",
            "release.ensure",
            "sync.sync",
            "phase: syncing the config tree",
            "open",
            "phase: starting the session",
            "session.start",
            "client.ensure",
            "session.takeover",
            "attach.prepare",
            "succeed",
        }, timeline(view))
    end)

    it("carries the provisioning sync and the session start in the same view as the install", function()
        local result, err = run { installed = true }

        assert.truthy(result, err)

        -- the sync's own phase line lands between the ladder's bookends
        assert.are.same(
            { "resolving the identity", "probing the session", "syncing the config tree", "starting the session" },
            phases_of(view)
        )
    end)

    it("opens the window at session start when neither install nor sync ran", function()
        local result, err = run { installed = false, has_marker = true }

        assert.truthy(result, err)
        assert.are.same({
            "phase: resolving the identity",
            "up.resolve",
            "phase: probing the session",
            "session.probe",
            "release.ensure",
            "sync.has_marker",
            "open",
            "phase: starting the session",
            "session.start",
            "client.ensure",
            "session.takeover",
            "attach.prepare",
            "succeed",
        }, timeline(view))
    end)

    it("announces the lossy-state warning on a restart path without changing the phase ladder", function()
        local result, err = run { installed = false, has_marker = true, probe = { state = "dead", remains = true } }

        assert.truthy(result, err)
        assert.truthy(reported[1].msg:find("fresh session", 1, true))
        assert.truthy(reported[1].msg:find("lost", 1, true))
        assert.truthy(contains(timeline(view), "phase: starting the session"))
    end)

    it("fails with the error streamed into the view when the provisioning sync fails", function()
        local result, err = run { installed = true, sync_err = "rsync failed for the config tree (exit 23)" }

        assert.is_nil(result)
        assert.truthy(err:find("provisioning sync failed", 1, true))

        local names = timeline(view)

        assert.falsy(contains(names, "session.start"), "no session may start after a failed sync")
        assert.falsy(contains(names, "open"), "a sync that failed before its transfer opened nothing")

        local last = view.events[#view.events - 1]
        local final = view.events[#view.events]

        assert.equal("stream", last.kind)
        assert.equal("stderr", last.source)
        assert.truthy(last.chunk:find("provisioning sync failed", 1, true))
        assert.equal("fail", final.kind)
        assert.equal(vim.log.levels.ERROR, reported[#reported].level)
    end)

    it("never opens a window when identity resolution fails", function()
        local result, err = run { resolve_err = "endpoint expansion failed" }

        assert.is_nil(result)
        assert.truthy(err:find("endpoint expansion failed", 1, true))
        assert.falsy(opened(view))
        assert.are.same({ "phase: resolving the identity", "up.resolve", "stream", "fail" }, timeline(view))
    end)

    it("backs one invocation with exactly one handle from the injected factory", function()
        stubs = {}
        view.events = {}

        replace(up, "resolve", function(_, _, callback)
            callback(RESOLVED, nil)
        end)
        replace(session, "probe", function(_, _, _, callback)
            callback({ state = "live", remains = false }, nil)
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

        local handles = {}

        up.run(TARGET, {
            registry_dir = registry_dir,
            progress = function()
                local handle = recording_view()

                table.insert(handles, handle)

                return handle
            end,
        }, function() end)

        revert_all()

        assert.equal(1, #handles)
        assert.equal("succeed", handles[1].events[#handles[1].events].kind)
    end)
end)

-- The warm path against the real handle: no window may appear and no
-- scratch buffer may survive.
describe("up progress view against the real handle", function()
    local config = require "outpost.config"

    it("a live-session up creates no window and no surviving buffer", function()
        local ui = pretend_ui()

        local stubs = {}

        local function replace(module, name, impl)
            helpers.replace(stubs, module, name, impl)
        end

        replace(up, "resolve", function(_, _, callback)
            callback(RESOLVED, nil)
        end)
        replace(session, "probe", function(_, _, _, callback)
            callback({ state = "live", remains = false }, nil)
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

        local handles = {}
        local windows_before = #vim.api.nvim_list_wins()
        local buffers_before = #vim.api.nvim_list_bufs()

        up.run(TARGET, {
            registry_dir = vim.fn.tempname(),
            progress = function()
                local handle = progress.create()

                table.insert(handles, handle)

                return handle
            end,
        }, function() end)

        for _, s in ipairs(stubs) do
            s:revert()
        end

        assert.equal(1, #handles)
        assert.equal(windows_before, #vim.api.nvim_list_wins(), "the fast path must not flicker a window")
        assert.equal(buffers_before, #vim.api.nvim_list_bufs(), "success leaves no buffer debris")

        ui:revert()
    end)

    it("opens no window for a cold ladder when setup disabled the view", function()
        config.setup { progress = false }

        local ui = pretend_ui()

        local stubs = {}

        local function replace(module, name, impl)
            helpers.replace(stubs, module, name, impl)
        end

        replace(up, "resolve", function(_, _, callback)
            callback(RESOLVED, nil)
        end)
        replace(session, "probe", function(_, _, _, callback)
            callback({ state = "dead", remains = false }, nil)
        end)
        replace(release, "ensure", function(_, opts, callback)
            callback({ platform = "linux-x86_64", home = RESOLVED.home, tag = "v0.2.0", installed = true }, nil)
        end)
        replace(sync, "sync", function(_, _, callback)
            callback({ stats = { files = 1, bytes = 10 } }, nil)
        end)
        local reported = {}
        local real_notify = vim.notify

        vim.notify = function(msg)
            table.insert(reported, msg)
        end

        local windows_before = #vim.api.nvim_list_wins()
        local result, err

        replace(session, "start", function(_, _, callback)
            -- mid-flight: success has not yet auto-closed anything
            assert.equal(windows_before, #vim.api.nvim_list_wins(), "a disabled view must never open a window")
            callback(true, nil)
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

        up.run(TARGET, { registry_dir = vim.fn.tempname() }, function(r, e)
            result, err = r, e
        end)

        vim.notify = real_notify

        for _, s in ipairs(stubs) do
            s:revert()
        end

        assert.truthy(result, err)
        assert.equal(windows_before, #vim.api.nvim_list_wins(), "a disabled view must leave no window behind")
        assert.truthy(reported[1]:find("started session " .. RESOLVED.session_id, 1, true), "nothing else changed")

        ui:revert()
        config.setup {}
    end)
end)
