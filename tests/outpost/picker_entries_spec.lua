-- Unit spec for picker source assembly (offline by construction: injected
-- registry entries and hosts, no probes, no vim.ui).

local picker = require "outpost.picker"

describe("picker entries", function()
    local function session(overrides)
        return vim.tbl_extend("force", {
            session_id = "00ac56",
            endpoint = "dev@10.0.0.4",
            canonical_path = "/srv/proj",
            typed_target = "dev@devbox:~/proj",
            state = "live",
            ["last-used"] = 100,
        }, overrides or {})
    end

    it("lists sessions before ssh-config hosts", function()
        local entries = picker.entries({ session() }, { "devbox", "alpha" })

        assert.equal("session", entries[1].kind)
        assert.equal("host", entries[2].kind)
        assert.equal("host", entries[3].kind)
    end)

    it("labels a session with id, recorded target, and state", function()
        local entries = picker.entries({ session() }, {})

        assert.equal("00ac56  dev@devbox:~/proj (live)", entries[1].label)
        assert.equal("dev@devbox:~/proj", entries[1].target)
        assert.equal("00ac56", entries[1].session_id)
    end)

    it("shows every registry entry regardless of state", function()
        local entries = picker.entries({
            session { session_id = "aaaaaa", state = "dead" },
            session { session_id = "bbbbbb", state = "unreachable" },
        }, {})

        assert.equal("aaaaaa  dev@devbox:~/proj (dead)", entries[1].label)
        assert.equal("bbbbbb  dev@devbox:~/proj (unreachable)", entries[2].label)
    end)

    it("orders sessions by last-used, most recent first", function()
        local entries = picker.entries({
            session { session_id = "aaaaaa", ["last-used"] = 10 },
            session { session_id = "bbbbbb", ["last-used"] = 30 },
            session { session_id = "cccccc", ["last-used"] = 20 },
        }, {})

        assert.equal("bbbbbb", entries[1].session_id)
        assert.equal("cccccc", entries[2].session_id)
        assert.equal("aaaaaa", entries[3].session_id)
    end)

    it("falls back to endpoint plus canonical path without a recorded target", function()
        local bare = session()

        bare.typed_target = nil

        local entries = picker.entries({ bare }, {})

        assert.equal("dev@10.0.0.4:/srv/proj", entries[1].target)
        assert.equal("00ac56  dev@10.0.0.4:/srv/proj (live)", entries[1].label)
    end)

    it("sorts hosts alphabetically and labels them as hosts", function()
        local entries = picker.entries({}, { "vps", "alpha", "devbox" })

        assert.equal("alpha  (ssh-config host)", entries[1].label)
        assert.equal("alpha", entries[1].host)
        assert.equal("devbox", entries[2].host)
        assert.equal("vps", entries[3].host)
    end)

    it("returns nothing when there are no sources", function()
        assert.are_same({}, picker.entries({}, {}))
    end)
end)
