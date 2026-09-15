-- Unit spec for bare-host expansion (offline: `ssh -G` reads a temp config
-- and never connects).

local up = require "outpost.up"

local await = require "outpost.await"

describe("up host expansion", function()
    it("resolves a bare ssh-config host to its effective user@hostname", function()
        local cfg = vim.fn.tempname()

        vim.fn.writefile({
            "Host outposttest",
            "  HostName 127.0.0.1",
            "  User dev",
        }, cfg)

        local result, err = unpack(await(up.expand_host, 10000, "outposttest", { ssh_config = cfg }))

        assert.truthy(result, err)
        assert.equal("dev@127.0.0.1", result)

        vim.fn.delete(cfg)
    end)
end)

describe("up target refusal", function()
    local function empty_config()
        local cfg = vim.fn.tempname()

        vim.fn.writefile({}, cfg)

        return cfg
    end

    it("refuses a literal target that resolves to the base's own account", function()
        local cfg = empty_config()

        local result, err = unpack(await(up.expand, 10000, "dev@127.0.0.1:~/proj", {
            ssh_config = cfg,
            base = "dev@127.0.0.1",
        }))

        assert.is_nil(result)
        assert.truthy(err:find("dev@127.0.0.1", 1, true))
        assert.truthy(err:lower():find("base", 1, true))

        vim.fn.delete(cfg)
    end)

    it("refuses an ssh-config alias that resolves back to the base", function()
        local cfg = vim.fn.tempname()

        vim.fn.writefile({
            "Host basebox",
            "  HostName 127.0.0.1",
            "  User dev",
        }, cfg)

        local result, err = unpack(await(up.expand, 10000, "dev@basebox:~/proj", {
            ssh_config = cfg,
            base = "dev@127.0.0.1",
        }))

        assert.is_nil(result)
        assert.truthy(err:find("dev@127.0.0.1", 1, true))

        vim.fn.delete(cfg)
    end)

    it("refuses a base-resolving host on the expansion-only path too", function()
        local cfg = empty_config()

        local result, err = unpack(await(up.expand_host, 10000, "dev@127.0.0.1", {
            ssh_config = cfg,
            base = "dev@127.0.0.1",
        }))

        assert.is_nil(result)
        assert.truthy(err:lower():find("base", 1, true))

        vim.fn.delete(cfg)
    end)

    it("still resolves a legitimate remote target", function()
        local cfg = empty_config()

        local result, err = unpack(await(up.expand, 10000, "dev@remote.example.com:~/proj", {
            ssh_config = cfg,
            base = "dev@127.0.0.1",
        }))

        assert.truthy(result, err)
        assert.equal("dev@remote.example.com", result)

        vim.fn.delete(cfg)
    end)

    it("refuses the live base account through an alias when no base is given", function()
        local endpoint = require "outpost.endpoint"
        local user, host = assert(endpoint.base()):match "^(.+)@(.+)$"
        local cfg = vim.fn.tempname()

        vim.fn.writefile({
            "Host livebase",
            "  HostName " .. host,
            "  User " .. user,
        }, cfg)

        local result, err = unpack(await(up.expand, 10000, user .. "@livebase:~/proj", { ssh_config = cfg }))

        assert.is_nil(result)
        assert.truthy(err:lower():find("base", 1, true))

        vim.fn.delete(cfg)
    end)
end)
