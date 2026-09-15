-- Unit specs for stop/down's bare-picker collection and selection (offline:
-- vim.ui stubbed, session.probe stubbed via injected registry_dir + a fake
-- prober opt).

local picker = require "outpost.picker"
local registry = require "outpost.registry"

local stub = require "luassert.stub"

describe("picker pick_stop", function()
    local dir
    local select_stub
    local notify_stub

    before_each(function()
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")

        select_stub = stub(vim.ui, "select")
        notify_stub = stub(vim, "notify")
    end)

    after_each(function()
        select_stub:revert()
        notify_stub:revert()
        vim.fn.delete(dir, "rf")
    end)

    it("offers live/dead sessions and runs the chosen session id", function()
        registry.record(dir, { session_id = "ab12cd", endpoint = "outpost@box", canonical_path = "/proj" })

        select_stub.invokes(function(items, _, callback)
            callback(items[1])
        end)

        local ran

        picker.pick_stop({
            registry_dir = dir,
            probe = function(_, _, _, callback)
                callback { state = "live" }
            end,
        }, function(session_id)
            ran = session_id
        end)

        assert.equal("ab12cd", ran)
    end)

    it("excludes an unreachable session from the offered list", function()
        registry.record(dir, { session_id = "ab12cd", endpoint = "outpost@box", canonical_path = "/proj" })

        picker.pick_stop({
            registry_dir = dir,
            probe = function(_, _, _, callback)
                callback(nil)
            end,
        }, function() end)

        assert.stub(select_stub).was_not_called()
        assert.stub(notify_stub).was_called(1)
    end)

    it("does nothing when the selection is cancelled", function()
        registry.record(dir, { session_id = "ab12cd", endpoint = "outpost@box", canonical_path = "/proj" })

        select_stub.invokes(function(_, _, callback)
            callback(nil)
        end)

        local ran = false

        picker.pick_stop({
            registry_dir = dir,
            probe = function(_, _, _, callback)
                callback { state = "live" }
            end,
        }, function()
            ran = true
        end)

        assert.equal(false, ran)
    end)
end)

describe("picker pick_down", function()
    local dir
    local select_stub

    before_each(function()
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")

        select_stub = stub(vim.ui, "select")
    end)

    after_each(function()
        select_stub:revert()
        vim.fn.delete(dir, "rf")
    end)

    it("offers registry-known hosts and runs the chosen host, with no probing", function()
        registry.record(dir, {
            session_id = "ab12cd",
            endpoint = "outpost@box",
            canonical_path = "/proj",
            typed_target = "dev@devbox:~/proj",
        })

        select_stub.invokes(function(items, _, callback)
            callback(items[1])
        end)

        local ran

        picker.pick_down({ registry_dir = dir }, function(host)
            ran = host
        end)

        assert.equal("devbox", ran)
    end)

    it("does nothing when the selection is cancelled", function()
        registry.record(dir, {
            session_id = "ab12cd",
            endpoint = "outpost@box",
            canonical_path = "/proj",
            typed_target = "dev@devbox:~/proj",
        })

        select_stub.invokes(function(_, _, callback)
            callback(nil)
        end)

        local ran = false

        picker.pick_down({ registry_dir = dir }, function()
            ran = true
        end)

        assert.equal(false, ran)
    end)
end)
