-- Integration spec: `list.run` end-to-end against the docker-sshd fixture -
-- scan, adopt, and registry-local GC/purge, observed through the registry
-- and the rendered report.

local list = require "outpost.list"
local present = require "outpost.present"
local registry = require "outpost.registry"
local session = require "outpost.session"
local up = require "outpost.up"

local harness = require "outpost.harness"
local await = require "outpost.await"

describe("list run", function()
    local opts
    local list_opts
    local registry_dir

    local real_report

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

        -- isolate list's host universe from the machine's real ssh config:
        -- only opts passed to list.run need this, not up.run's own calls
        list_opts = vim.tbl_extend("force", opts, { ssh_config = vim.fn.tempname() .. ".none" })

        real_report = present.report

        harness.remote "rm -rf $HOME/.cache/outpost/run"
        harness.remote "mkdir -p $HOME/proj"
    end)

    after_each(function()
        present.report = real_report

        if registry_dir then
            vim.fn.delete(registry_dir, "rf")
        end
    end)

    it("reports a live session and does not touch its registry entry", function()
        if not harness.pending_unless_up() then
            return
        end

        local result, err = unpack(await(up.run, 180000, "outpost@127.0.0.1:~/proj", opts))

        assert.truthy(result, err)

        local reported

        present.report = function(lines)
            reported = lines
        end

        list.run(nil, list_opts)

        assert.truthy(vim.wait(60000, function()
            return reported ~= nil
        end))

        assert.equal(1, #reported)
        assert.truthy(reported[1]:find(result.session_id, 1, true))
        assert.truthy(reported[1]:find("live", 1, true))
        assert.truthy(registry.get(registry_dir, result.session_id), "the live entry must survive")
    end)

    it("adopts a session on the remote that the local registry never recorded", function()
        if not harness.pending_unless_up() then
            return
        end

        -- start a session directly (bypassing up/register) so it exists only
        -- on the remote's run/ directory, never in this registry
        local resolve, resolve_err = unpack(await(up.resolve, nil, "outpost@127.0.0.1:~/proj", opts))

        assert.truthy(resolve, resolve_err)

        local started, start_err = unpack(await(session.start, nil, resolve, opts))

        assert.truthy(started, start_err)
        assert.is_nil(registry.get(registry_dir, resolve.session_id))

        -- the host is known via ssh-config (never registered): list must
        -- still discover it there and scan it
        vim.fn.writefile({ "Host 127.0.0.1", "  User outpost" }, list_opts.ssh_config)

        local reported

        present.report = function(lines)
            reported = lines
        end

        list.run(nil, list_opts)

        assert.truthy(vim.wait(60000, function()
            return reported ~= nil
        end))

        local found = false

        for _, line in ipairs(reported) do
            if line:find(resolve.session_id, 1, true) then
                found = true
            end
        end

        assert.truthy(found, "list must adopt a session it found on the remote")
    end)

    it("gcs a dead entry from the registry without touching a live one", function()
        if not harness.pending_unless_up() then
            return
        end

        local result, err = unpack(await(up.run, 180000, "outpost@127.0.0.1:~/proj", opts))

        assert.truthy(result, err)

        -- kill the server directly so the registry entry goes stale (dead:
        -- ssh reachable, no server) without going through stop
        local pid = vim.trim(harness.remote(("cat %s"):format(session.paths(result.session_id).pid)).out)

        harness.remote(("kill -KILL %s"):format(pid))
        assert.truthy(vim.wait(2000, function()
            return harness.remote(("kill -0 %s"):format(pid)).code ~= 0
        end))

        present.report = function() end

        list.run(nil, list_opts)

        assert.truthy(
            vim.wait(60000, function()
                return registry.get(registry_dir, result.session_id) == nil
            end),
            "list must GC the dead entry"
        )
    end)

    it("keeps an unreachable entry unless banged", function()
        if not harness.pending_unless_up() then
            return
        end

        registry.record(registry_dir, {
            session_id = "ffffff",
            endpoint = "outpost@does-not-resolve.invalid",
            canonical_path = "/nowhere",
        })

        present.report = function() end

        list.run(nil, vim.tbl_extend("force", list_opts, { bang = false }))

        vim.wait(3000)

        assert.truthy(registry.get(registry_dir, "ffffff"), "plain list must not purge unreachable entries")

        list.run(nil, vim.tbl_extend("force", list_opts, { bang = true }))

        assert.truthy(
            vim.wait(60000, function()
                return registry.get(registry_dir, "ffffff") == nil
            end),
            "list! must purge unreachable entries"
        )
    end)

    it("scopes the scan to one host when given", function()
        if not harness.pending_unless_up() then
            return
        end

        local result, err = unpack(await(up.run, 180000, "outpost@127.0.0.1:~/proj", opts))

        assert.truthy(result, err)

        registry.record(registry_dir, {
            session_id = "ffffff",
            endpoint = "outpost@does-not-resolve.invalid",
            canonical_path = "/nowhere",
        })

        local reported

        present.report = function(lines)
            reported = lines
        end

        list.run("127.0.0.1", list_opts)

        assert.truthy(vim.wait(60000, function()
            return reported ~= nil
        end))

        local mentions_scoped_host = false
        local mentions_other_host = false

        for _, line in ipairs(reported) do
            if line:find(result.session_id, 1, true) then
                mentions_scoped_host = true
            end

            if line:find("ffffff", 1, true) then
                mentions_other_host = true
            end
        end

        assert.truthy(mentions_scoped_host)
        assert.falsy(mentions_other_host, "scoping to one host must not scan the other")
    end)
end)
