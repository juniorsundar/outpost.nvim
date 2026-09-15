-- Unit specs for the stop/down picker source filters (offline: injected
-- registry entries, no probes, no vim.ui).

local picker = require "outpost.picker"

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

describe("picker stop_entries", function()
    it("offers a live session", function()
        local entries = picker.stop_entries { session { state = "live" } }

        assert.equal(1, #entries)
        assert.equal("session", entries[1].kind)
    end)

    it("offers a dead session", function()
        local entries = picker.stop_entries { session { state = "dead" } }

        assert.equal(1, #entries)
    end)

    it("excludes an unreachable session", function()
        local entries = picker.stop_entries { session { state = "unreachable" } }

        assert.same({}, entries)
    end)

    it("orders live/dead sessions most-recently-used first", function()
        local entries = picker.stop_entries {
            session { session_id = "aaaaaa", ["last-used"] = 10, state = "live" },
            session { session_id = "bbbbbb", ["last-used"] = 30, state = "dead" },
        }

        assert.equal("bbbbbb", entries[1].session_id)
        assert.equal("aaaaaa", entries[2].session_id)
    end)
end)

describe("picker down_entries", function()
    it("lists each host with at least one registry entry", function()
        local entries = picker.down_entries {
            session { session_id = "aaaaaa", typed_target = "dev@devbox:~/proj" },
        }

        assert.equal(1, #entries)
        assert.equal("host", entries[1].kind)
        assert.equal("devbox", entries[1].host)
    end)

    it("does not duplicate a host with multiple sessions", function()
        local entries = picker.down_entries {
            session { session_id = "aaaaaa", typed_target = "dev@devbox:~/a" },
            session { session_id = "bbbbbb", typed_target = "dev@devbox:~/b" },
        }

        assert.equal(1, #entries)
    end)

    it("sorts hosts alphabetically", function()
        local entries = picker.down_entries {
            session { session_id = "aaaaaa", typed_target = "dev@vps:~/a" },
            session { session_id = "bbbbbb", typed_target = "dev@alpha:~/b" },
        }

        assert.equal("alpha", entries[1].host)
        assert.equal("vps", entries[2].host)
    end)

    it("includes every state, since down does not care about liveness", function()
        local entries = picker.down_entries {
            session { session_id = "aaaaaa", typed_target = "dev@devbox:~/a", state = "unreachable" },
        }

        assert.equal(1, #entries)
    end)

    it("returns nothing when the registry is empty", function()
        assert.same({}, picker.down_entries {})
    end)
end)
