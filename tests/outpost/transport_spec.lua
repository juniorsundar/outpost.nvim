-- Unit spec for remote command assembly (offline by construction).

local harness = require "outpost.harness"
local await = require "outpost.await"
local transport = require "outpost.transport"

describe("transport option assembly", function()
    it("builds the non-interactive ssh option set", function()
        local args = transport.ssh_args {
            port = "2222",
            key = "tests/outpost/.keys/id_ed25519",
            known_hosts = "tests/outpost/.keys/known_hosts",
        }

        assert.are.same({
            "-p",
            "2222",
            "-i",
            "tests/outpost/.keys/id_ed25519",
            "-o",
            "StrictHostKeyChecking=accept-new",
            "-o",
            "UserKnownHostsFile=tests/outpost/.keys/known_hosts",
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=2",
        }, args)
    end)

    it("matches the harness's option assembly given the same details", function()
        local conn = {
            port = harness.port(),
            key = harness.key(),
            known_hosts = harness.known_hosts(),
        }

        assert.are.same(harness.ssh_args(), transport.ssh_args(conn))
    end)

    it("scp spells the port flag -P and keeps every other option", function()
        local args = transport.scp_args {
            port = "2222",
            key = "tests/outpost/.keys/id_ed25519",
            known_hosts = "tests/outpost/.keys/known_hosts",
        }

        assert.are.same({
            "-P",
            "2222",
            "-i",
            "tests/outpost/.keys/id_ed25519",
            "-o",
            "StrictHostKeyChecking=accept-new",
            "-o",
            "UserKnownHostsFile=tests/outpost/.keys/known_hosts",
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=2",
        }, args)
    end)

    it("omits options for unprovided connection details", function()
        assert.are.same({
            "-p",
            "2200",
            "-o",
            "StrictHostKeyChecking=accept-new",
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=2",
        }, transport.ssh_args { port = "2200" })

        assert.are.same({
            "-i",
            "tests/outpost/.keys/id_ed25519",
            "-o",
            "StrictHostKeyChecking=accept-new",
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=2",
        }, transport.ssh_args { key = "tests/outpost/.keys/id_ed25519" })
    end)

    it("defaults to a bare invocation with no options", function()
        assert.are.same({}, transport.ssh_args())
        assert.are.same({}, transport.ssh_args(nil))
        assert.are.same({}, transport.ssh_args {})
        assert.are.same({}, transport.scp_args())
    end)
end)

describe("transport execution", function()
    local conn, target

    before_each(function()
        conn = {
            port = harness.port(),
            key = harness.key(),
            known_hosts = harness.known_hosts(),
        }
        target = harness.target()
    end)

    it("runs a remote command and returns its code and stdout", function()
        if not harness.pending_unless_up() then
            return
        end

        local code, out = unpack(await(transport.run, nil, target, "printf transport-ok", conn))

        assert.equal(0, code)
        assert.equal("transport-ok", vim.trim(out))
    end)

    it("propagates a failing remote command", function()
        if not harness.pending_unless_up() then
            return
        end

        local code, _, err = unpack(await(transport.run, nil, target, "printf to-stderr 1>&2; exit 3", conn))

        assert.equal(3, code)
        assert.truthy(err and err:find("to-stderr", 1, true))
    end)

    it("uploads a file over scp", function()
        if not harness.pending_unless_up() then
            return
        end

        local local_tmp = vim.fn.tempname()

        vim.fn.writefile({ "transport roundtrip" }, local_tmp)

        local ok = unpack(await(transport.upload, nil, target, local_tmp, "/tmp/outpost-transport-roundtrip", conn))

        assert.truthy(ok)

        local content = harness.remote "cat /tmp/outpost-transport-roundtrip"

        assert.equal("transport roundtrip", vim.trim(content.out))

        harness.remote "rm -f /tmp/outpost-transport-roundtrip"
        vim.fn.delete(local_tmp)
    end)
end)
