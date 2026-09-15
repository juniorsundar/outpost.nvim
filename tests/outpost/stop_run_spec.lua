-- Integration spec: `stop.run`'s three resolved-state paths against the
-- docker-sshd fixture.

local session = require "outpost.session"
local stop = require "outpost.stop"
local registry = require "outpost.registry"
local up = require "outpost.up"

local harness = require "outpost.harness"
local await = require "outpost.await"

local stub = require "luassert.stub"

describe("stop run", function()
    local opts
    local registry_dir

    local real_notify

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
            bang = true,
        }

        real_notify = vim.notify

        harness.remote "rm -rf $HOME/.cache/outpost/run"
        harness.remote "mkdir -p $HOME/proj"
    end)

    after_each(function()
        vim.notify = real_notify

        if registry_dir then
            vim.fn.delete(registry_dir, "rf")
        end
    end)

    it("stops a live session: kills the server, drops run/, drops the registry entry", function()
        if not harness.pending_unless_up() then
            return
        end

        local result, err = unpack(await(up.run, 180000, "outpost@127.0.0.1:~/proj", opts))

        assert.truthy(result, err)

        local sid = result.session_id
        local paths = session.paths(sid)

        stop.run(sid, opts)

        assert.truthy(
            vim.wait(30000, function()
                return registry.get(registry_dir, sid) == nil
            end),
            "the registry entry must be dropped"
        )

        assert.equal(1, harness.remote(("test -d %s"):format(paths.root)).code)
    end)

    it("tidies a dead session: no server to kill, still cleans up", function()
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

        stop.run(sid, opts)

        assert.truthy(
            vim.wait(30000, function()
                return registry.get(registry_dir, sid) == nil
            end),
            "the registry entry must be dropped even for a dead session"
        )

        assert.equal(1, harness.remote(("test -d %s"):format(paths.root)).code)
    end)

    it("errors on an unreachable session and leaves it flagged in the registry", function()
        if not harness.pending_unless_up() then
            return
        end

        registry.record(registry_dir, {
            session_id = "ffffff",
            endpoint = "outpost@does-not-resolve.invalid",
            canonical_path = "/nowhere",
        })

        local reported

        vim.notify = function(msg)
            reported = msg
        end

        stop.run("ffffff", opts)

        assert.truthy(vim.wait(15000, function()
            return reported ~= nil
        end))

        assert.truthy(reported:find("can't reach", 1, true))
        assert.truthy(registry.get(registry_dir, "ffffff"), "an unreachable entry must stay in the registry")
    end)

    it("confirms unless banged: a 'No' answer stops nothing", function()
        if not harness.pending_unless_up() then
            return
        end

        local result, err = unpack(await(up.run, 180000, "outpost@127.0.0.1:~/proj", opts))

        assert.truthy(result, err)

        local select_stub = stub(vim.ui, "select")

        select_stub.invokes(function(items, _, callback)
            callback(items[2]) -- "No"
        end)

        local unbanged = vim.tbl_extend("force", opts, { bang = false })

        stop.run(result.session_id, unbanged)

        vim.wait(3000)

        select_stub:revert()

        assert.truthy(registry.get(registry_dir, result.session_id), "declining the confirm must stop nothing")
    end)
end)
