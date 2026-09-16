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
            "-o",
            "ControlMaster=auto",
            "-o",
            "ControlPath=" .. vim.fs.joinpath(vim.fn.stdpath "cache", "outpost", "mux", "%C"),
            "-o",
            "ControlPersist=10m",
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
            "-o",
            "NumberOfPasswordPrompts=1",
        }, args)
    end)

    it("matches the harness's option assembly given the same details", function()
        local conn = {
            port = harness.port(),
            key = harness.key(),
            known_hosts = harness.known_hosts(),
            askpass = false,
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
            "-o",
            "ControlMaster=auto",
            "-o",
            "ControlPath=" .. vim.fs.joinpath(vim.fn.stdpath "cache", "outpost", "mux", "%C"),
            "-o",
            "ControlPersist=10m",
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
            "-o",
            "NumberOfPasswordPrompts=1",
        }, args)
    end)

    it("keeps per-connection details conditional", function()
        local port_args = transport.ssh_args { port = "2200" }
        local key_args = transport.ssh_args { key = "tests/outpost/.keys/id_ed25519" }

        assert.truthy(vim.tbl_contains(port_args, "2200"))
        assert.falsy(vim.tbl_contains(port_args, "tests/outpost/.keys/id_ed25519"))
        assert.truthy(vim.tbl_contains(key_args, "tests/outpost/.keys/id_ed25519"))
        assert.falsy(vim.tbl_contains(key_args, "2200"))
    end)

    it("always includes baseline and mux options for an empty connection", function()
        local expected = {
            "-o",
            "ControlMaster=auto",
            "-o",
            "ControlPath=" .. vim.fs.joinpath(vim.fn.stdpath "cache", "outpost", "mux", "%C"),
            "-o",
            "ControlPersist=10m",
            "-o",
            "StrictHostKeyChecking=accept-new",
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=2",
            "-o",
            "NumberOfPasswordPrompts=1",
        }

        assert.are.same(expected, transport.ssh_args())
        assert.are.same(expected, transport.ssh_args(nil))
        assert.are.same(expected, transport.ssh_args {})
        assert.are.same(expected, transport.scp_args())
    end)
end)

describe("transport multiplexing", function()
    local mux_options = {
        "-o",
        "ControlMaster=auto",
        "-o",
        "ControlPath=" .. vim.fs.joinpath(vim.fn.stdpath "cache", "outpost", "mux", "%C"),
        "-o",
        "ControlPersist=10m",
    }

    it("muxes connections by default and allows an explicit opt-out", function()
        local args = transport.ssh_args { mux = true }

        assert.are.same(mux_options, { args[1], args[2], args[3], args[4], args[5], args[6] })
        assert.falsy(vim.tbl_contains(transport.ssh_args { mux = false }, "ControlMaster=auto"))
    end)

    it("keeps the per-endpoint control path under the local cache", function()
        local path = vim.fs.joinpath(vim.fn.stdpath "cache", "outpost", "mux", "%C")
        local args = transport.ssh_args { mux = true }

        assert.truthy(vim.tbl_contains(args, "ControlPath=" .. path))
    end)

    it("creates the default mux directory for an empty connection", function()
        transport.ensure_mux_dir(nil)

        assert.equal(1, vim.fn.isdirectory(vim.fs.joinpath(vim.fn.stdpath "cache", "outpost", "mux")))
    end)

    it("lets an injected control path replace the cache path", function()
        local args = transport.ssh_args { mux = true, mux_path = "/tmp/mux/%C" }

        assert.truthy(vim.tbl_contains(args, "ControlPath=/tmp/mux/%C"))
    end)

    it("carries the options on scp too, alongside the rest", function()
        local expected = vim.deepcopy(mux_options)

        vim.list_extend(expected, {
            "-P",
            "2222",
            "-o",
            "StrictHostKeyChecking=accept-new",
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=2",
            "-o",
            "NumberOfPasswordPrompts=1",
        })

        assert.are.same(expected, transport.scp_args { mux = true, port = "2222" })
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

    it("runs the script under POSIX sh, not the remote login shell", function()
        if not harness.pending_unless_up() then
            return
        end

        -- word splitting differs between the fixture's zsh login shell and
        -- sh, so this only passes if the script is executed by sh
        local code, out = unpack(await(transport.run, nil, target, 'CMD="echo login-shell-independent"; $CMD', conn))

        assert.equal(0, code)
        assert.equal("login-shell-independent", vim.trim(out))
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

describe("transport multiplexing execution", function()
    local dir
    local conn

    before_each(function()
        dir = vim.fn.tempname()
        conn = {
            port = harness.port(),
            key = harness.key(),
            known_hosts = harness.known_hosts(),
            mux = true,
            mux_path = vim.fs.joinpath(dir, "master.sock"),
        }
    end)

    after_each(function()
        -- stop the persisted master before removing its socket directory
        vim.fn.system {
            "ssh",
            "-O",
            "exit",
            "-p",
            harness.port(),
            "-i",
            harness.key(),
            "-o",
            "StrictHostKeyChecking=accept-new",
            "-o",
            "UserKnownHostsFile=" .. harness.known_hosts(),
            "-o",
            "BatchMode=yes",
            "-o",
            "ControlPath=" .. conn.mux_path,
            harness.target(),
        }

        vim.fn.delete(dir, "rf")
    end)

    it("reuses one authenticated connection for sequential commands", function()
        if not harness.pending_unless_up() then
            return
        end

        local client = function()
            local out = (await(transport.run, 30000, harness.target(), "printf '%s' \"$SSH_CLIENT\"", conn))[2]

            return vim.trim(out)
        end

        local first = client()
        local second = client()

        assert.truthy(first ~= "", "the fixture must report its ssh client")
        -- a muxed connection is one TCP connection: same client both times
        assert.equal(first, second, "sequential commands must reuse the master")
        assert.equal("socket", vim.fn.getftype(conn.mux_path), "the control socket must exist")
    end)
end)

describe("askpass and BatchMode", function()
    local config = require "outpost.config"

    after_each(function()
        config.setup {}
    end)

    it("sets BatchMode when the bridge is not installed", function()
        config.setup {}

        assert.truthy(vim.tbl_contains(transport.ssh_args(), "BatchMode=yes"))
        assert.truthy(vim.tbl_contains(transport.scp_args(), "BatchMode=yes"))
    end)

    it("omits BatchMode when the bridge is installed", function()
        config.setup { askpass = true }

        assert.falsy(vim.tbl_contains(transport.ssh_args(), "BatchMode=yes"))
        assert.falsy(vim.tbl_contains(transport.scp_args(), "BatchMode=yes"))
    end)

    it("lets a per-connection override install the bridge", function()
        config.setup {}

        assert.falsy(vim.tbl_contains(transport.ssh_args { askpass = true }, "BatchMode=yes"))
    end)
end)
