-- Unit spec for the registry (offline by construction: temp dirs only).

local registry = require "outpost.registry"

local stub = require "luassert.stub"

describe("registry", function()
    local dir
    local time_stub

    before_each(function()
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
    end)

    after_each(function()
        if time_stub then
            time_stub:revert()
            time_stub = nil
        end

        vim.fn.delete(dir, "rf")
    end)

    it("records a session retrievable by session id", function()
        registry.record(dir, {
            session_id = "00ac56",
            endpoint = "dev@127.0.0.1",
            canonical_path = "/srv/code/proj",
            typed_target = "dev@fixturebox:~/code/proj",
        })

        local entry = registry.get(dir, "00ac56")

        assert.equal("dev@127.0.0.1", entry.endpoint)
        assert.equal("/srv/code/proj", entry.canonical_path)
        assert.equal("dev@fixturebox:~/code/proj", entry.typed_target)
        assert.truthy(entry["last-used"] > 0)
    end)

    it("keeps sessions as separate entries under their ids", function()
        registry.record(dir, { session_id = "00ac56", endpoint = "dev@one", canonical_path = "/a" })
        registry.record(dir, { session_id = "b488dd", endpoint = "dev@two", canonical_path = "/b" })

        assert.equal("dev@one", registry.get(dir, "00ac56").endpoint)
        assert.equal("dev@two", registry.get(dir, "b488dd").endpoint)
    end)

    it("re-recording a session updates its entry in place", function()
        registry.record(dir, { session_id = "00ac56", endpoint = "dev@old", canonical_path = "/a" })
        registry.record(dir, { session_id = "00ac56", endpoint = "dev@new", canonical_path = "/a" })

        local entry = registry.get(dir, "00ac56")

        assert.equal("dev@new", entry.endpoint)

        local all = registry.all(dir)

        assert.equal(1, vim.tbl_count(all))
    end)

    it("stamps last-used on every record", function()
        local timestamps = { 1700000000, 1700000001 }
        local calls = 0

        time_stub = stub(os, "time")
        time_stub.invokes(function()
            calls = calls + 1
            return timestamps[calls]
        end)

        registry.record(dir, { session_id = "00ac56", endpoint = "dev@one", canonical_path = "/a" })
        local first = registry.get(dir, "00ac56")["last-used"]

        registry.record(dir, { session_id = "00ac56", endpoint = "dev@one", canonical_path = "/a" })
        local second = registry.get(dir, "00ac56")["last-used"]

        assert.equal(timestamps[1], first)
        assert.equal(timestamps[2], second)
    end)

    it("creates the registry directory when it does not exist yet", function()
        local fresh = vim.fs.joinpath(dir, "nested", "outpost")

        registry.record(fresh, { session_id = "00ac56", endpoint = "dev@one", canonical_path = "/a" })

        assert.equal("dev@one", registry.get(fresh, "00ac56").endpoint)
    end)

    it("reads as an empty table when nothing has been recorded", function()
        assert.are_same({}, registry.all(dir))
    end)

    it("survives a corrupted cache file as an empty registry", function()
        vim.fn.writefile({ "not json {{{" }, vim.fs.joinpath(dir, "sessions.json"))

        assert.are_same({}, registry.all(dir))
    end)

    it("returns nil for an unknown session id", function()
        assert.is_nil(registry.get(dir, "ffffff"))
    end)

    it("removes a session entry", function()
        registry.record(dir, { session_id = "00ac56", endpoint = "dev@one", canonical_path = "/a" })

        registry.remove(dir, "00ac56")

        assert.is_nil(registry.get(dir, "00ac56"))
    end)

    it("removing an unknown session id is not an error", function()
        registry.remove(dir, "ffffff")

        assert.are_same({}, registry.all(dir))
    end)
end)

describe("registry host_of", function()
    it("reads the host out of a recorded typed target", function()
        assert.equal("devbox", registry.host_of { typed_target = "dev@devbox:~/proj" })
    end)

    it("falls back to the endpoint's host when there is no typed target", function()
        assert.equal("10.0.0.4", registry.host_of { endpoint = "dev@10.0.0.4" })
    end)

    it("is nil when neither is present", function()
        assert.is_nil(registry.host_of {})
    end)
end)
