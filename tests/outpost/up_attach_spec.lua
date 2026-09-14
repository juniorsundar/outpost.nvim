-- Integration spec: `up` generates a self-contained attach script at the
-- expected cache path, named by session id, and the script owns its tunnel -
-- it comes up, then tears down on termination. Gated on the docker-sshd
-- fixture; the first pin downloads the real bundle, so it also needs
-- internet.

local up = require "outpost.up"
local attach = require "outpost.attach"

local harness = require "outpost.harness"
local await = require "outpost.await"

describe("up attach script", function()
    local opts
    local registry_dir
    local attach_dir

    -- one download cache and one pinned-client cache for the whole spec
    local cache_dir
    local client_dir

    local stub
    local job

    before_each(function()
        if not harness.pending_unless_up() then
            return
        end

        registry_dir = vim.fn.tempname()
        vim.fn.mkdir(registry_dir, "p")

        attach_dir = vim.fn.tempname()
        cache_dir = cache_dir or vim.fn.tempname()
        client_dir = client_dir or vim.fn.tempname()

        opts = {
            conn = {
                port = harness.port(),
                key = harness.key(),
                known_hosts = harness.known_hosts(),
            },
            registry_dir = registry_dir,
            cache_dir = cache_dir,
            client_dir = client_dir,
            attach_dir = attach_dir,
        }

        stub = vim.fn.tempname() .. ".sh"
        -- exec so the stub's pid is the sleep itself: the script's cleanup
        -- can then terminate it directly (a shell waiting on a child would
        -- leave the grandchild behind)
        vim.fn.writefile({ "#!/bin/sh", "exec sleep 300" }, stub)
        vim.uv.fs_chmod(stub, 493)

        harness.remote "mkdir -p $HOME/proj"
    end)

    after_each(function()
        vim.env.OUTPOST_NVIM = nil

        if job and job > 0 then
            vim.fn.jobstop(job)
            job = nil
        end

        vim.fn.delete(stub)
        vim.fn.delete(registry_dir, "rf")
        vim.fn.delete(attach_dir, "rf")
    end)

    -- A live session for the spec, without paying for the real pin.
    local function live_session()
        vim.env.OUTPOST_NVIM = stub

        local result, err = unpack(await(up.run, 180000, "outpost@127.0.0.1:~/proj", opts))

        assert.truthy(result, err)

        return result
    end

    it("generates an executable script named by session id that references the pinned client", function()
        if not harness.pending_unless_up() then
            return
        end

        local result, err = unpack(await(up.run, 180000, "outpost@127.0.0.1:~/proj", opts))

        assert.truthy(result, err)

        -- the script is where the spec says it is, named by session id
        assert.equal(attach.path(result.session_id, attach_dir), result.command)
        assert.equal(1, vim.fn.executable(result.command))

        local script = table.concat(vim.fn.readfile(result.command), "\n")

        -- and it execs the pinned attach client of the remote's tag
        assert.truthy(script:find(result.client, 1, true))
        assert.truthy(result.client:find(result.tag, 1, true))
        assert.truthy(script:find(attach.socket_path(result.session_id, attach_dir), 1, true))

        -- the script reaches the fixture with the same non-interactive
        -- options the control plane uses: it must never prompt for auth
        assert.truthy(script:find(harness.port(), 1, true))
        assert.truthy(script:find(harness.key(), 1, true))
        assert.truthy(script:find("BatchMode=yes", 1, true))
    end)

    it("honors the OUTPOST_NVIM override in the generated script", function()
        if not harness.pending_unless_up() then
            return
        end

        local result = live_session()
        local script = table.concat(vim.fn.readfile(result.command), "\n")

        assert.equal(stub, result.client)
        assert.truthy(script:find(stub, 1, true))
    end)

    it("creates the tunneled local socket and tears down the tunnel and socket on termination", function()
        if not harness.pending_unless_up() then
            return
        end

        local result = live_session()
        local sock = attach.socket_path(result.session_id, attach_dir)

        local function tunnel_pids()
            return vim.fn.systemlist { "pgrep", "-f", sock }
        end

        -- the script runs standalone: a fresh process, no nvim state
        job = vim.fn.jobstart { result.command }

        assert.truthy(job > 0, "the script must run as a standalone executable")

        assert.truthy(
            vim.wait(10000, function()
                return vim.fn.getftype(sock) == "socket"
            end),
            "the tunneled local socket must appear"
        )

        assert.truthy(
            vim.wait(5000, function()
                return #tunnel_pids() > 0
            end),
            "the tunnel process must be running"
        )

        -- closing the terminal signals the script and the foreground client
        -- together; the trap fires once the client is gone. Wait for both the
        -- tunnel and the client to be up before signalling.
        local script_pid = tostring(vim.fn.jobpid(job))

        assert.truthy(
            vim.wait(5000, function()
                return #vim.fn.systemlist { "pgrep", "-P", script_pid } >= 2
            end),
            "the tunnel and the foreground client must both be running"
        )

        local pids = { script_pid }

        vim.list_extend(pids, vim.fn.systemlist { "pgrep", "-P", script_pid })

        local kill = { "kill", "-TERM" }

        vim.list_extend(kill, pids)
        vim.fn.system(kill)

        assert.truthy(
            vim.wait(10000, function()
                return vim.fn.getftype(sock) == ""
            end),
            "teardown must remove the local socket"
        )

        assert.truthy(
            vim.wait(10000, function()
                return #tunnel_pids() == 0
            end),
            "the tunnel process must not outlive the script"
        )
    end)
end)
