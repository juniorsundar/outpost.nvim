-- Unit spec for target parsing (offline by construction).

local target = require "outpost.target"

describe("target parsing", function()
    it("splits user@host:path into its parts", function()
        assert.are_same({
            user = "dev",
            host = "box",
            path = "~/code/proj",
        }, target.parse "dev@box:~/code/proj")
    end)

    it("accepts an absolute path", function()
        local parsed = target.parse "dev@box:/srv/code/proj"

        assert.equal("dev", parsed.user)
        assert.equal("box", parsed.host)
        assert.equal("/srv/code/proj", parsed.path)
    end)

    it("accepts a path with an at-sign in it", function()
        local parsed = target.parse "dev@box:~/code/user@proj"

        assert.equal("dev", parsed.user)
        assert.equal("box", parsed.host)
        assert.equal("~/code/user@proj", parsed.path)
    end)

    it("refuses a target without a path", function()
        local parsed, err = target.parse "dev@box"

        assert.is_nil(parsed)
        assert.equal("not a target: dev@box (expected user@host:path)", err)
    end)

    it("refuses a target without a user", function()
        local parsed, err = target.parse "box:~/code/proj"

        assert.is_nil(parsed)
        assert.equal("not a target: box:~/code/proj (expected user@host:path)", err)
    end)

    it("refuses a bare path with no host at all", function()
        local parsed, err = target.parse "~/code/proj"

        assert.is_nil(parsed)
        assert.equal("not a target: ~/code/proj (expected user@host:path)", err)
    end)

    it("refuses an empty user", function()
        local parsed, err = target.parse "@box:~/code/proj"

        assert.is_nil(parsed)
        assert.equal("not a target: @box:~/code/proj (expected user@host:path)", err)
    end)

    it("refuses an empty host", function()
        local parsed, err = target.parse "dev@:~/code/proj"

        assert.is_nil(parsed)
        assert.equal("not a target: dev@:~/code/proj (expected user@host:path)", err)
    end)

    it("refuses an empty path", function()
        local parsed, err = target.parse "dev@box:"

        assert.is_nil(parsed)
        assert.equal("not a target: dev@box: (expected user@host:path)", err)
    end)
end)
