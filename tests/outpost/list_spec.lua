-- Unit specs for `list`'s pure logic: merging a remote scan with the local
-- registry, classifying state, and the GC-vs-purge decision. Offline: state
-- and scan results are injected, no probes or ssh.

local list = require "outpost.list"

describe("list merge", function()
    it("adopts a session the scan found that the registry never recorded", function()
        local merged = list.merge({}, { { session_id = "ab12cd", canonical_path = "/a", endpoint = "outpost@box" } })

        assert.equal(1, #merged)
        assert.equal("ab12cd", merged[1].session_id)
        assert.equal("/a", merged[1].canonical_path)
    end)

    it("keeps a registry entry the scan did not find (host unreachable)", function()
        local merged = list.merge({
            ab12cd = { endpoint = "outpost@box", canonical_path = "/a" },
        }, nil)

        assert.equal(1, #merged)
        assert.equal("ab12cd", merged[1].session_id)
    end)

    it("prefers the registry's typed_target when both know the session", function()
        local merged = list.merge({
            ab12cd = { endpoint = "outpost@box", canonical_path = "/a", typed_target = "dev@box:/a" },
        }, { { session_id = "ab12cd", canonical_path = "/a", endpoint = "outpost@box" } })

        assert.equal(1, #merged)
        assert.equal("dev@box:/a", merged[1].typed_target)
    end)

    it("does not duplicate a session known to both sources", function()
        local merged = list.merge({
            ab12cd = { endpoint = "outpost@box", canonical_path = "/a" },
        }, { { session_id = "ab12cd", canonical_path = "/a", endpoint = "outpost@box" } })

        assert.equal(1, #merged)
    end)
end)

describe("list gc_and_purge", function()
    local function entry(state)
        return { session_id = "ab12cd", state = state }
    end

    it("drops dead entries unconditionally", function()
        local kept, removed = list.gc_and_purge({ entry "dead" }, false)

        assert.same({}, kept)
        assert.same({ "ab12cd" }, removed)
    end)

    it("keeps unreachable entries when not banged", function()
        local kept, removed = list.gc_and_purge({ entry "unreachable" }, false)

        assert.equal(1, #kept)
        assert.same({}, removed)
    end)

    it("drops unreachable entries when banged", function()
        local kept, removed = list.gc_and_purge({ entry "unreachable" }, true)

        assert.same({}, kept)
        assert.same({ "ab12cd" }, removed)
    end)

    it("always keeps live entries", function()
        local kept, removed = list.gc_and_purge({ entry "live" }, true)

        assert.equal(1, #kept)
        assert.same({}, removed)
    end)
end)

describe("list render", function()
    it("renders one line per entry: session id, target, state", function()
        local lines = list.render {
            {
                session_id = "ab12cd",
                typed_target = "dev@box:/a",
                endpoint = "outpost@box",
                canonical_path = "/a",
                state = "live",
            },
        }

        assert.equal(1, #lines)
        assert.truthy(lines[1]:find("ab12cd", 1, true))
        assert.truthy(lines[1]:find("dev@box:/a", 1, true))
        assert.truthy(lines[1]:find("live", 1, true))
    end)

    it("falls back to endpoint:path when there is no typed target", function()
        local lines = list.render {
            { session_id = "ab12cd", endpoint = "outpost@box", canonical_path = "/a", state = "dead" },
        }

        assert.truthy(lines[1]:find("outpost@box:/a", 1, true))
    end)

    it("reports plainly when there is nothing to show", function()
        assert.same({ "outpost: no sessions found" }, list.render {})
    end)
end)
