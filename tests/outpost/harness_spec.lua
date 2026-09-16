local harness = require "outpost.harness"

describe("harness option assembly", function()
    it("targets user@host", function()
        assert.equal("outpost@127.0.0.1", harness.target())
    end)

    it("assembles non-interactive ssh options", function()
        local joined = table.concat(harness.ssh_args(), " ")

        assert.truthy(joined:find("-p 2222", 1, true))
        assert.truthy(joined:find("StrictHostKeyChecking=accept-new", 1, true))
        assert.truthy(joined:find("UserKnownHostsFile=", 1, true))
        assert.truthy(joined:find("BatchMode=yes", 1, true))
        assert.truthy(joined:find("ConnectTimeout=2", 1, true))
        assert.truthy(joined:find("ControlMaster=auto", 1, true))
        assert.truthy(joined:find("ControlPersist=10m", 1, true))

        local args = harness.ssh_args()
        for i, arg in ipairs(args) do
            if arg == "-i" then
                assert.truthy(args[i + 1] and #args[i + 1] > 0)
            end
        end
    end)

    it("scp spells the port flag -P and keeps every other option", function()
        local joined = table.concat(harness.scp_args(), " ")

        assert.truthy(joined:find("-P 2222", 1, true))
        assert.falsy(joined:find("-p 2222", 1, true))
        assert.truthy(joined:find("StrictHostKeyChecking=accept-new", 1, true))
        assert.truthy(joined:find("BatchMode=yes", 1, true))
    end)
end)

describe("harness integration gate", function()
    local integration, live, real_pending
    local gate

    before_each(function()
        integration, live = vim.env.OUTPOST_TEST_INTEGRATION, vim.env.OUTPOST_TEST_LIVE_RELEASE
        real_pending = _G.pending
        gate = dofile "tests/outpost/harness.lua"
    end)

    after_each(function()
        vim.env.OUTPOST_TEST_INTEGRATION, vim.env.OUTPOST_TEST_LIVE_RELEASE = integration, live
        _G.pending = real_pending
    end)

    it("never probes SSH in an offline run", function()
        vim.env.OUTPOST_TEST_INTEGRATION = "0"
        local skipped = false
        _G.pending = function()
            skipped = true
        end
        gate.is_up = function()
            error "offline tests must not probe SSH"
        end
        assert.is_false(gate.pending_unless_up())
        assert.is_true(skipped)
    end)

    it("fails instead of silently skipping an explicitly requested integration run", function()
        vim.env.OUTPOST_TEST_INTEGRATION = "1"
        gate.is_up = function()
            return false
        end
        assert.has_error(function()
            gate.pending_unless_up()
        end, "harness not running - run `make harness-up`")
    end)

    it("probes only once per spec process", function()
        vim.env.OUTPOST_TEST_INTEGRATION = "1"
        vim.env.OUTPOST_TEST_LIVE_RELEASE = "1"
        local calls = 0
        gate.is_up = function()
            calls = calls + 1
            return true
        end
        assert.is_true(gate.pending_unless_up())
        assert.is_true(gate.pending_unless_up())
        assert.equal(1, calls)
    end)
end)

describe("harness fixture", function()
    it("answers an ssh probe", function()
        if not harness.pending_unless_up() then
            return
        end

        local result = harness.remote "printf outpost-ok"

        assert.equal(0, result.code, result.out)
        assert.equal("outpost-ok", vim.trim(result.out))
    end)

    it("has a writable home directory", function()
        if not harness.pending_unless_up() then
            return
        end

        local result = harness.remote "touch $HOME/.outpost-write-test && rm $HOME/.outpost-write-test"

        assert.equal(0, result.code, result.out)
    end)

    it("scp round-trips a file to the fixture", function()
        if not harness.pending_unless_up() then
            return
        end

        local local_tmp = vim.fn.tempname()

        vim.fn.writefile({ "outpost roundtrip" }, local_tmp)

        local up_argv = { "scp" }

        vim.list_extend(up_argv, harness.scp_args())
        table.insert(up_argv, local_tmp)
        table.insert(up_argv, harness.target() .. ":/tmp/outpost-roundtrip")

        local up = vim.fn.system(up_argv)

        assert.equal(0, vim.v.shell_error, up)

        local content = harness.remote "cat /tmp/outpost-roundtrip"

        assert.equal("outpost roundtrip", vim.trim(content.out))

        harness.remote "rm -f /tmp/outpost-roundtrip"
        vim.fn.delete(local_tmp)
    end)
end)
