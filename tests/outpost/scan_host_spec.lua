-- Integration spec: scan.host against the docker-sshd fixture.

local scan = require "outpost.scan"
local up = require "outpost.up"

local harness = require "outpost.harness"
local await = require "outpost.await"

describe("scan host", function()
    local opts
    local registry_dir

    before_each(function()
        if not harness.pending_unless_up() then
            return
        end

        registry_dir = vim.fn.tempname()
        vim.fn.mkdir(registry_dir, "p")

        opts = {
            conn = {
                port = harness.port(),
                key = harness.key(),
                known_hosts = harness.known_hosts(),
            },
            registry_dir = registry_dir,
            cache_dir = vim.fn.tempname(),
            client_dir = vim.fn.tempname(),
            attach_dir = vim.fn.tempname(),
        }

        harness.remote "rm -rf $HOME/.cache/outpost/run"
        harness.remote "mkdir -p $HOME/proj"
    end)

    after_each(function()
        if registry_dir then
            vim.fn.delete(registry_dir, "rf")
        end
    end)

    it("finds a live session's manifest", function()
        if not harness.pending_unless_up() then
            return
        end

        local result, err = unpack(await(up.run, 180000, "outpost@127.0.0.1:~/proj", opts))

        assert.truthy(result, err)

        local entries, scan_err = unpack(await(scan.host, nil, "outpost@127.0.0.1", opts.conn))

        assert.truthy(entries, scan_err)
        assert.equal(1, #entries)
        assert.equal(result.session_id, entries[1].session_id)
        assert.equal("/home/outpost/proj", entries[1].canonical_path)
        assert.equal("outpost@127.0.0.1", entries[1].endpoint)
    end)

    it("reports no sessions on an outpost with no run/ directory", function()
        if not harness.pending_unless_up() then
            return
        end

        local entries, scan_err = unpack(await(scan.host, nil, "outpost@127.0.0.1", opts.conn))

        assert.same({}, entries)
        assert.falsy(scan_err)
    end)
end)
