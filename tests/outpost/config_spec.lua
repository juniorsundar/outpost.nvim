-- Unit spec for the setup-time configuration (offline by construction).

local config = require "outpost.config"

describe("outpost config", function()
    after_each(function()
        config.setup {}
    end)

    it("defaults to no multiplexing", function()
        config.setup {}

        assert.falsy(config.mux "vps")
    end)

    it("enables multiplexing only for configured hosts", function()
        config.setup { hosts = { vps = { mux = true } } }

        assert.truthy(config.mux "vps")
        assert.falsy(config.mux "other")
        assert.falsy(config.mux(nil))
    end)

    it("ignores a configured host without the mux flag", function()
        config.setup { hosts = { vps = {} } }

        assert.falsy(config.mux "vps")
    end)

    it("returns connection details with multiplexing enabled for a muxed host", function()
        config.setup { hosts = { vps = { mux = true } } }

        local conn = config.conn("vps", { port = "2222" })

        assert.truthy(conn.mux)
        assert.equal("2222", conn.port)
    end)

    it("leaves connection details untouched for an unmuxed host", function()
        config.setup {}

        local conn = config.conn("vps", { port = "2222" })

        assert.falsy(conn.mux)
        assert.equal("2222", conn.port)
    end)

    it("does not mutate the caller's connection table", function()
        config.setup { hosts = { vps = { mux = true } } }

        local base = { port = "2222" }

        config.conn("vps", base)

        assert.falsy(base.mux)
    end)
end)
