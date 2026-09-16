-- Integration spec: `down.run` end-to-end against the docker-sshd fixture -
-- session count in the confirm, kills the live session, and removes
-- everything under ~/.cache/outpost.

local down = require "outpost.down"
local registry = require "outpost.registry"
local up = require "outpost.up"

local harness = require "outpost.harness"
local await = require "outpost.await"

local stub = require "luassert.stub"

describe("down run", function()
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
        }

        real_notify = vim.notify

        harness.remote "rm -rf $HOME/.cache/outpost"
        harness.remote "mkdir -p $HOME/proj"
    end)

    after_each(function()
        vim.notify = real_notify

        if registry_dir then
            vim.fn.delete(registry_dir, "rf")
        end
    end)

    it("reports the live session count in its confirm, then destroys the outpost", function()
        if not harness.pending_unless_up() then
            return
        end

        local result, err = unpack(await(up.run, 180000, "outpost@127.0.0.1:~/proj", opts))

        assert.truthy(result, err)

        local select_stub = stub(vim.ui, "select")
        local prompt

        select_stub.invokes(function(items, select_opts, callback)
            prompt = select_opts.prompt
            callback(items[1]) -- "Yes"
        end)

        local reported

        vim.notify = function(msg)
            reported = msg
        end

        down.run("127.0.0.1", vim.tbl_extend("force", opts, { endpoint = "outpost@127.0.0.1" }))

        assert.truthy(vim.wait(60000, function()
            return reported ~= nil
        end))

        select_stub:revert()

        assert.truthy(prompt:find("1 session", 1, true), "confirm must report the concrete session count: " .. prompt)
        assert.truthy(reported:find("destroyed", 1, true))

        assert.is_nil(registry.get(registry_dir, result.session_id))

        -- everything under ~/.cache/outpost is gone
        assert.equal(1, harness.remote("test -d $HOME/.cache/outpost").code)

        -- the process itself is dead, not just the directory
        assert.equal(1, harness.remote(("kill -0 %s"):format(result.session_id)).code)
    end)

    it("skips the confirm when banged", function()
        if not harness.pending_unless_up() then
            return
        end

        local result, err = unpack(await(up.run, 180000, "outpost@127.0.0.1:~/proj", opts))

        assert.truthy(result, err)

        local select_stub = stub(vim.ui, "select")

        local reported

        vim.notify = function(msg)
            reported = msg
        end

        down.run("127.0.0.1", vim.tbl_extend("force", opts, { endpoint = "outpost@127.0.0.1", bang = true }))

        assert.truthy(vim.wait(60000, function()
            return reported ~= nil
        end))

        select_stub:revert()

        assert.stub(select_stub).was_not_called()
        assert.equal(1, harness.remote("test -d $HOME/.cache/outpost").code)
    end)

    it("does nothing when the confirm is declined", function()
        if not harness.pending_unless_up() then
            return
        end

        local result, err = unpack(await(up.run, 180000, "outpost@127.0.0.1:~/proj", opts))

        assert.truthy(result, err)

        local select_stub = stub(vim.ui, "select")
        local prompt
        local callback_returned

        select_stub.invokes(function(items, select_opts, callback)
            prompt = select_opts.prompt
            callback(items[2]) -- "No"
            callback_returned = true
        end)

        down.run("127.0.0.1", vim.tbl_extend("force", opts, { endpoint = "outpost@127.0.0.1" }))

        assert.truthy(
            vim.wait(60000, function()
                return callback_returned
            end),
            "declining the confirm must return from its select callback"
        )

        select_stub:revert()

        assert.truthy(prompt, "declining the confirm must reach the prompt")
        assert.equal(0, harness.remote("test -d $HOME/.cache/outpost").code)
        assert.truthy(registry.get(registry_dir, result.session_id))
    end)

    it("works for a host with no registry entries at all", function()
        if not harness.pending_unless_up() then
            return
        end

        -- provision on the remote directly, bypassing up/register, so the
        -- registry never learns about this host
        harness.remote "mkdir -p $HOME/.cache/outpost/run/ffffff"
        harness.remote "echo fake > $HOME/.cache/outpost/run/ffffff/manifest.json"

        assert.is_nil(registry.get(registry_dir, "ffffff"))

        local select_stub = stub(vim.ui, "select")

        select_stub.invokes(function(items, _, callback)
            callback(items[1]) -- "Yes"
        end)

        local reported

        vim.notify = function(msg)
            reported = msg
        end

        down.run("127.0.0.1", vim.tbl_extend("force", opts, { endpoint = "outpost@127.0.0.1" }))

        assert.truthy(vim.wait(60000, function()
            return reported ~= nil
        end))

        select_stub:revert()

        assert.truthy(reported:find("destroyed", 1, true))
        assert.equal(1, harness.remote("test -d $HOME/.cache/outpost").code)
    end)
end)
