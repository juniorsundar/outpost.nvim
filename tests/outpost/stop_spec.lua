-- Unit specs for stop's target resolution: classifying short vs. long form,
-- and the branching between a registry lookup and the identity ladder.
-- Offline: the ladder resolver is injected, and the registry is a temp dir
-- (no network for either branch).

local stop = require "outpost.stop"
local registry = require "outpost.registry"

local await = require "outpost.await"

describe("stop is_session_id", function()
    it("recognizes a 6-hex-char session id", function()
        assert.is_true(stop.is_session_id "ab12cd")
    end)

    it("rejects a long-form target", function()
        assert.is_false(stop.is_session_id "dev@box:~/proj")
    end)

    it("rejects something that merely looks short", function()
        assert.is_false(stop.is_session_id "abcdefg")
        assert.is_false(stop.is_session_id "abcd")
        assert.is_false(stop.is_session_id "zzzzzz")
    end)
end)

describe("stop resolve: short form", function()
    local dir

    before_each(function()
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
    end)

    after_each(function()
        vim.fn.delete(dir, "rf")
    end)

    it("resolves a known session id via the registry, with no network", function()
        registry.record(dir, { session_id = "ab12cd", endpoint = "outpost@box", canonical_path = "/proj" })

        local resolved, err = unpack(await(stop.resolve, nil, "ab12cd", { registry_dir = dir }))

        assert.truthy(resolved, err)
        assert.equal("ab12cd", resolved.session_id)
        assert.equal("outpost@box", resolved.endpoint)
        assert.equal("/proj", resolved.canonical_path)
    end)

    it("errors clearly, naming :Outpost list, on an unknown session id", function()
        local resolved, err = unpack(await(stop.resolve, nil, "ffffff", { registry_dir = dir }))

        assert.is_nil(resolved)
        assert.truthy(err:find("ffffff", 1, true))
        assert.truthy(err:find(":Outpost list", 1, true))
    end)
end)

describe("stop resolve: long form", function()
    it("re-runs the identity ladder and never writes the registry", function()
        local received_target

        local resolved, err = unpack(await(stop.resolve, nil, "dev@box:~/proj", {
            resolve_long = function(target_str, _, callback)
                received_target = target_str
                callback({
                    session_id = "34ef56",
                    endpoint = "dev@boxhost",
                    canonical_path = "/home/dev/proj",
                }, nil)
            end,
        }))

        assert.equal("dev@box:~/proj", received_target)
        assert.truthy(resolved, err)
        assert.equal("34ef56", resolved.session_id)
        assert.equal("dev@boxhost", resolved.endpoint)
        assert.equal("/home/dev/proj", resolved.canonical_path)
    end)

    it("propagates a ladder failure instead of resolving", function()
        local resolved, err = unpack(await(stop.resolve, nil, "dev@box:~/proj", {
            resolve_long = function(_, _, callback)
                callback(nil, "no project directory on dev@boxhost: ~/proj")
            end,
        }))

        assert.is_nil(resolved)
        assert.truthy(err:find("no project directory", 1, true))
    end)
end)
