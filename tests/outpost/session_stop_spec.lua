-- Specs for session.stop: killing a session's server process and removing
-- its remote directory. Fixture-gated for the actual kill; the transport
-- error path is offline.

local session = require "outpost.session"
local up = require "outpost.up"

local harness = require "outpost.harness"
local await = require "outpost.await"

describe("session stop against a live session", function()
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

        harness.remote "mkdir -p $HOME/proj"
    end)

    after_each(function()
        if registry_dir then
            vim.fn.delete(registry_dir, "rf")
        end
    end)

    it("kills the server process and removes the session directory", function()
        if not harness.pending_unless_up() then
            return
        end

        local result, err = unpack(await(up.run, 180000, "outpost@127.0.0.1:~/proj", opts))

        assert.truthy(result, err)

        local sid = result.session_id
        local paths = session.paths(sid)
        local pid = vim.trim(harness.remote(("cat %s"):format(paths.pid)).out)

        assert.truthy(pid:match "^%d+$", "the start script must have recorded a pid")

        local ok, stop_err = unpack(await(session.stop, nil, "outpost@127.0.0.1", sid, opts.conn))

        assert.truthy(ok, stop_err)

        -- the process is actually gone
        assert.equal(1, harness.remote(("kill -0 %s"):format(pid)).code)

        -- the whole session directory is gone, not just the socket
        assert.equal(1, harness.remote(("test -d %s"):format(paths.root)).code)
    end)

    it("tidies up a session that is already dead: process gone, directory still removed", function()
        if not harness.pending_unless_up() then
            return
        end

        local result, err = unpack(await(up.run, 180000, "outpost@127.0.0.1:~/proj", opts))

        assert.truthy(result, err)

        local sid = result.session_id
        local paths = session.paths(sid)
        local pid = vim.trim(harness.remote(("cat %s"):format(paths.pid)).out)

        harness.remote(("kill -KILL %s"):format(pid))

        assert.truthy(vim.wait(2000, function()
            return harness.remote(("kill -0 %s"):format(pid)).code ~= 0
        end))

        local ok, stop_err = unpack(await(session.stop, nil, "outpost@127.0.0.1", sid, opts.conn))

        assert.truthy(ok, stop_err)
        assert.equal(1, harness.remote(("test -d %s"):format(paths.root)).code)
    end)
end)

describe("session stop transport failure", function()
    it("reports the transport error instead of pretending success", function()
        local ok, err = unpack(await(session.stop, nil, "nobody@does-not-resolve.invalid", "ab12cd", {
            key = "/nonexistent",
        }))

        assert.falsy(ok)
        assert.truthy(err)
    end)
end)
