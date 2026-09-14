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
