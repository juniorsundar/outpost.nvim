-- Unit spec for session id computation (offline by construction).

local identity = require "outpost.identity"

describe("session id computation", function()
    local instance_id = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"

    it("is the first six hex chars of the digest", function()
        -- sha256("a1b2c3d4-e5f6-7890-abcd-ef1234567890:/srv/code/proj")
        --   = 00ac5629a8e5...  (verified with sha256sum)
        assert.equal("00ac56", identity.session_id(instance_id, "/srv/code/proj"))
    end)

    it("is six characters long", function()
        assert.equal(6, #identity.session_id(instance_id, "~/code/proj"))
    end)

    it("is lowercase hex", function()
        local id = identity.session_id(instance_id, "~/code/proj")

        assert.truthy(id:find "^[0-9a-f]+$", id)
    end)

    it("distinguishes paths - a different project is a different session", function()
        local one = identity.session_id(instance_id, "/srv/code/proj")
        local other = identity.session_id(instance_id, "/srv/code/other")

        assert.not_equal(one, other)
    end)

    it("distinguishes outposts - a different instance id is a different session", function()
        local one = identity.session_id(instance_id, "/srv/code/proj")
        local other = identity.session_id("00000000-0000-0000-0000-000000000000", "/srv/code/proj")

        assert.not_equal(one, other)
    end)

    it("joins instance id and path with a separator, not bare concatenation", function()
        -- sha256("a...890" .. ":" .. "/srv/code/proj") = 00ac56...,
        -- while the bare concatenation hashes to b488dd... (sha256sum).
        -- The ":"-joined form is normative.
        assert.equal("00ac56", identity.session_id(instance_id, "/srv/code/proj"))
        assert.not_equal("b488dd", identity.session_id(instance_id, "/srv/code/proj"))
    end)
end)
