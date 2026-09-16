-- Unit spec for the setup-time configuration (offline by construction).

local config = require "outpost.config"

describe("outpost config", function()
    after_each(function()
        config.setup {}
    end)

    it("defaults to multiplexing", function()
        config.setup {}

        assert.truthy(config.mux "vps")
    end)

    it("enables multiplexing only for configured hosts", function()
        config.setup { hosts = { vps = { mux = true } } }

        assert.truthy(config.mux "vps")
        assert.truthy(config.mux "other")
        assert.truthy(config.mux(nil))
    end)

    it("allows a host to opt out of multiplexing", function()
        config.setup { hosts = { vps = { mux = false } } }

        assert.falsy(config.mux "vps")
    end)

    it("returns connection details with multiplexing enabled for a muxed host", function()
        config.setup { hosts = { vps = { mux = true } } }

        local conn = config.conn("vps", { port = "2222" })

        assert.truthy(conn.mux)
        assert.equal("2222", conn.port)
    end)

    it("adds default multiplexing to an unconfigured host", function()
        config.setup {}

        local conn = config.conn("vps", { port = "2222" })

        assert.truthy(conn.mux)
        assert.equal("2222", conn.port)
    end)

    it("keeps an explicitly opted-out host unmuxed", function()
        config.setup { hosts = { vps = { mux = false } } }

        assert.falsy(config.conn("vps").mux)
    end)

    it("does not mutate the caller's connection table", function()
        config.setup { hosts = { vps = { mux = true } } }

        local base = { port = "2222" }

        config.conn("vps", base)

        assert.falsy(base.mux)
    end)
end)

describe("outpost sync excludes", function()
    after_each(function()
        config.setup {}
    end)

    it("defaults to no user excludes", function()
        config.setup {}

        assert.are_same({}, config.sync_exclude())
    end)

    it("returns the configured patterns in order", function()
        config.setup { sync = { exclude = { "node_modules/", "*.log" } } }

        assert.are_same({ "node_modules/", "*.log" }, config.sync_exclude())
    end)

    it("ignores a sync block that is not a table", function()
        for _, hostile in ipairs { true, 42, "scratch/" } do
            config.setup { sync = hostile }

            assert.are_same({}, config.sync_exclude())
        end
    end)

    it("ignores an exclude list that is not a table", function()
        config.setup { sync = { exclude = "scratch/" } }

        assert.are_same({}, config.sync_exclude())
    end)
end)
