-- Unit spec for the `up` ladder's provisioning-sync gate (offline: every
-- collaborator is stubbed at the module seam). Asserts what the ladder
-- decides and in what order: fresh-install sync, missing-marker retry,
-- failure abort, marker-stand skip, and the live-session short circuit.

local attach = require "outpost.attach"
local client = require "outpost.client"
local release = require "outpost.release"
local session = require "outpost.session"
local sync = require "outpost.sync"
local up = require "outpost.up"

local await = require "outpost.await"

local stub = require "luassert.stub"

local TARGET = "outpost@127.0.0.1:~/proj"

local RESOLVED = {
    target = { user = "outpost", host = "127.0.0.1", path = "~/proj" },
    endpoint = "outpost@127.0.0.1",
    instance_id = "0f0f0f0f-0000-0000-0000-000000000000",
    canonical_path = "/home/outpost/proj",
    home = "/home/outpost",
    session_id = "a1b2c3",
}

describe("up provisioning sync", function()
    local stubs
    local calls
    local order
    local reported
    local real_notify
    local opts

    local function record(name)
        calls[name] = (calls[name] or 0) + 1
        table.insert(order, name)
    end

    -- Replace a module field with a recording stub labelled `label`; the
    -- bare function names collide across modules, so the label is what the
    -- assertions read.
    local function replace(module, name, label, impl)
        local s = stub(module, name)

        s.invokes(function(...)
            record(label)
            return impl(...)
        end)

        table.insert(stubs, s)
    end

    local function revert()
        for _, s in ipairs(stubs) do
            s:revert()
        end

        stubs = {}
        calls = {}
        order = {}
    end

    -- Drive up.run with the flow seam stubbed; `state` tunes the responses.
    local function drive(state)
        state = state or {}
        revert()

        replace(up, "resolve", "up.resolve", function(_, _, callback)
            callback(RESOLVED, nil)
        end)

        replace(session, "probe", "session.probe", function(_, _, _, callback)
            callback(state.probe or { state = "dead", remains = false }, nil)
        end)

        replace(release, "usable_install", "release.usable_install", function(_, _, callback)
            callback "v0.2.0"
        end)

        replace(release, "ensure", "release.ensure", function(_, _, callback)
            callback({
                platform = "linux-x86_64",
                home = RESOLVED.home,
                tag = "v0.2.0",
                installed = state.installed == true,
            }, nil)
        end)

        replace(sync, "has_marker", "sync.has_marker", function(_, _, callback)
            callback(state.has_marker, state.marker_err)
        end)

        replace(sync, "sync", "sync.sync", function(_, _, callback)
            if state.sync_err then
                callback(nil, state.sync_err, "")
                return
            end

            callback({ stats = { files = 1, bytes = 10 } }, nil)
        end)

        replace(session, "start", "session.start", function(_, _, callback)
            callback(true, nil)
        end)

        replace(session, "takeover", "session.takeover", function(_, _, _, callback)
            callback(0, nil)
        end)

        replace(client, "ensure", "client.ensure", function(_, _, callback)
            callback("/tmp/pinned-client", nil)
        end)

        replace(attach, "prepare", "attach.prepare", function()
            return "/tmp/attach.sh"
        end)

        return unpack(await(up.run, 5000, TARGET, opts))
    end

    local function position(name)
        for index, entry in ipairs(order) do
            if entry == name then
                return index
            end
        end
    end

    before_each(function()
        stubs = {}
        calls = {}
        order = {}
        reported = {}

        real_notify = vim.notify
        vim.notify = function(msg, level)
            table.insert(reported, { msg = msg, level = level })
        end

        opts = { registry_dir = vim.fn.tempname() .. "-registry", attach_dir = vim.fn.tempname() }

        vim.fn.mkdir(opts.registry_dir, "p")
    end)

    after_each(function()
        vim.notify = real_notify
        revert()
        vim.fn.delete(opts.registry_dir, "rf")
    end)

    it("syncs a freshly installed outpost before starting its session", function()
        local result, err = drive { installed = true }

        assert.truthy(result, err)
        assert.equal(1, calls["sync.sync"])
        assert.equal(1, calls["session.start"])

        -- the install already proves the outpost unsynced: no marker probe
        assert.is_nil(calls["sync.has_marker"])
        assert.truthy(position "sync.sync" < position "session.start")
    end)

    it("syncs an outpost installed by update alone, whose marker is missing", function()
        local result, err = drive { installed = false, has_marker = false }

        assert.truthy(result, err)
        assert.equal(1, calls["sync.has_marker"])
        assert.equal(1, calls["sync.sync"])
        assert.equal(1, calls["session.start"])
        assert.truthy(position "sync.has_marker" < position "sync.sync")
        assert.truthy(position "sync.sync" < position "session.start")
    end)

    it("never syncs while the outpost's marker stands", function()
        local result, err = drive { installed = false, has_marker = true }

        assert.truthy(result, err)
        assert.equal(1, calls["sync.has_marker"])
        assert.is_nil(calls["sync.sync"])
        assert.equal(1, calls["session.start"])
    end)

    it("aborts before any session when the provisioning sync fails, then retries on the next up", function()
        local result, err = drive {
            installed = true,
            sync_err = "rsync failed for the config tree (exit 23)",
        }

        assert.is_nil(result)
        assert.truthy(err:find("provisioning sync failed", 1, true))
        assert.truthy(err:find("rsync failed for the config tree", 1, true))
        assert.is_nil(calls["session.start"])

        assert.equal(vim.log.levels.ERROR, reported[#reported].level)
        assert.truthy(reported[#reported].msg:find("provisioning sync failed", 1, true))

        -- the failed sync left no marker: the next up probes it and syncs again
        local retried, retry_err = drive { installed = false, has_marker = false }

        assert.truthy(retried, retry_err)
        assert.equal(1, calls["sync.has_marker"])
        assert.equal(1, calls["sync.sync"])
        assert.equal(1, calls["session.start"])
    end)

    it("aborts before any session when the marker probe fails", function()
        local result, err = drive { installed = false, has_marker = nil, marker_err = "sync marker probe failed" }

        assert.is_nil(result)
        assert.truthy(err:find("sync marker probe failed", 1, true))
        assert.is_nil(calls["sync.sync"])
        assert.is_nil(calls["session.start"])
    end)

    it("leaves a live session untouched - no install, no gate, straight to the attach command", function()
        local result, err = drive { probe = { state = "live", remains = false } }

        assert.truthy(result, err)
        assert.equal("/tmp/attach.sh", result.command)
        assert.equal("/tmp/pinned-client", result.client)

        assert.is_nil(calls["release.ensure"])
        assert.is_nil(calls["sync.has_marker"])
        assert.is_nil(calls["sync.sync"])
        assert.is_nil(calls["session.start"])
        assert.truthy(reported[#reported].msg:find("already live", 1, true))
    end)
end)
