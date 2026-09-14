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
