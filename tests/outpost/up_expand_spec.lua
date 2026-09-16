-- Unit spec for bare-host expansion (offline: `ssh -G` reads a temp config
-- and never connects).

local target = require "outpost.target"
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

        local result, err = unpack(await(up.expand, 10000, target.parse "dev@127.0.0.1:~/proj", {
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

        local result, err = unpack(await(up.expand, 10000, target.parse "dev@basebox:~/proj", {
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

        local result, err = unpack(await(up.expand, 10000, target.parse "dev@remote.example.com:~/proj", {
            ssh_config = cfg,
            base = "dev@127.0.0.1",
        }))

        assert.truthy(result, err)
        assert.equal("dev@remote.example.com", result)

        vim.fn.delete(cfg)
    end)

    it("refuses the live base account through an alias when no base is given", function()
        local user, host = assert(up.base()):match "^(.+)@(.+)$"
        local cfg = vim.fn.tempname()

        vim.fn.writefile({
            "Host livebase",
            "  HostName " .. host,
            "  User " .. user,
        }, cfg)

        local result, err =
            unpack(await(up.expand, 10000, target.parse(user .. "@livebase:~/proj"), { ssh_config = cfg }))

        assert.is_nil(result)
        assert.truthy(err:lower():find("base", 1, true))

        vim.fn.delete(cfg)
    end)
end)

describe("up expansion askpass bridge", function()
    local auth = require "outpost.auth"
    local config = require "outpost.config"

    local stub = require "luassert.stub"

    after_each(function()
        config.setup {}
    end)

    it("installs the askpass bridge for the expansion call", function()
        local cfg = vim.fn.tempname()

        vim.fn.writefile({
            "Host outposttest",
            "  HostName 127.0.0.1",
            "  User dev",
        }, cfg)

        local env_stub = stub(auth, "env").returns({ SSH_ASKPASS = "/helper" }, function() end)

        local result, err = unpack(await(up.expand_host, 10000, "outposttest", {
            ssh_config = cfg,
            conn = { askpass = true },
        }))

        assert.truthy(result, err)
        assert.equal("dev@127.0.0.1", result)
        assert.stub(env_stub).was_called()
        assert.equal("outposttest", env_stub.calls[1].refs[1])
        assert.truthy(env_stub.calls[1].refs[2].askpass)

        env_stub:revert()
        vim.fn.delete(cfg)
    end)
end)

-- Endpoint expansion and base detection (folded from the endpoint
-- module; offline by construction).

describe("endpoint expansion", function()
    -- Recorded from `ssh -G fixturebox` against a config declaring
    -- HostName 127.0.0.1 / Port 2222 / User dev.
    local recorded = table.concat({
        "user dev",
        "hostname 127.0.0.1",
        "port 2222",
    }, "\n")

    it("builds the endpoint from the resolved user and hostname", function()
        assert.equal("dev@127.0.0.1", up.from_ssh_g(recorded))
    end)

    it("ignores the recorded port - endpoints carry no port", function()
        local endpoint_str = up.from_ssh_g(recorded)

        assert.falsy(endpoint_str:find "2222")
    end)

    it("reads values among the full ssh -G field set", function()
        -- `ssh -G` emits many fields; user/hostname are not adjacent.
        local full = table.concat({
            "user dev",
            "hostkeyalias none",
            "hostname 127.0.0.1",
            "port 2222",
            "addressfamily any",
        }, "\n")

        assert.equal("dev@127.0.0.1", up.from_ssh_g(full))
    end)

    it("keeps the resolved user, not a typed one", function()
        local full = "user other\nhostname remote.example.com\nport 22\n"

        assert.equal("other@remote.example.com", up.from_ssh_g(full))
    end)
end)

describe("endpoint base detection", function()
    it("matches when the resolved endpoint names the base's own account", function()
        assert.is_true(up.is_base("dev@127.0.0.1", "dev@127.0.0.1"))
    end)

    it("does not match a different account", function()
        assert.is_false(up.is_base("outpost@127.0.0.1", "dev@127.0.0.1"))
    end)

    it("does not match a different host for the same user", function()
        assert.is_false(up.is_base("dev@remote.example.com", "dev@127.0.0.1"))
    end)

    it("compares against the live base account when none is given", function()
        assert.is_true(up.is_base(up.base()))
    end)
end)
