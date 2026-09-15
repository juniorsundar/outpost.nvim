-- Integration spec: `sync.run` end-to-end against the docker-sshd fixture -
-- the trees land under the outpost's XDG home, the marker exists, the
-- exclusion floor holds, --delete removes remote-only material, and the
-- roots stay private. Gated on the fixture being up.

local present = require "outpost.present"
local registry = require "outpost.registry"
local release = require "outpost.release"
local session = require "outpost.session"
local sync = require "outpost.sync"
local up = require "outpost.up"

local harness = require "outpost.harness"
local await = require "outpost.await"

local stub = require "luassert.stub"

describe("sync run", function()
    local registry_dir
    local cache_dir
    local client_dir
    local opts

    local real_notify
    local notifications
    local report_stub

    before_each(function()
        if not harness.pending_unless_up() then
            return
        end

        registry_dir = vim.fn.tempname()
        vim.fn.mkdir(registry_dir, "p")

        -- one download/pinned-client cache shared across spec runs (keyed
        -- by tag and platform, as in production; checksums self-heal a
        -- stale cache)
        cache_dir = cache_dir or "/tmp/outpost-sync-spec/downloads"
        client_dir = client_dir or "/tmp/outpost-sync-spec/clients"

        opts = {
            conn = {
                port = harness.port(),
                key = harness.key(),
                known_hosts = harness.known_hosts(),
            },
            registry_dir = registry_dir,
            endpoint = "outpost@127.0.0.1",
            cache_dir = cache_dir,
            client_dir = client_dir,
            attach_dir = vim.fn.tempname(),
        }

        real_notify = vim.notify
        notifications = {}

        vim.notify = function(msg, level)
            table.insert(notifications, { msg = msg, level = level })
        end

        report_stub = stub(present, "report")

        harness.remote "mkdir -p $HOME/proj"
    end)

    after_each(function()
        if real_notify then
            vim.notify = real_notify
        end

        if report_stub then
            report_stub:revert()
        end

        if registry_dir then
            vim.fn.delete(registry_dir, "rf")
        end
    end)

    it("points at :Outpost up when there is no outpost", function()
        if not harness.pending_unless_up() then
            return
        end

        harness.remote "rm -rf $HOME/.cache/outpost"

        sync.run("127.0.0.1", opts)

        assert.truthy(vim.wait(30000, function()
            return #notifications >= 2
        end))

        assert.equal(vim.log.levels.INFO, notifications[1].level)
        assert.equal(vim.log.levels.ERROR, notifications[2].level)
        assert.truthy(notifications[2].msg:find("Outpost up", 1, true))
        assert.equal(1, harness.remote("test -e $HOME/.cache/outpost/synced").code)
    end)
    it("points at :Outpost update when the outpost predates the rsync bundle", function()
        if not harness.pending_unless_up() then
            return
        end

        harness.remote "rm -rf $HOME/.cache/outpost"
        harness.remote "mkdir -p $HOME/.cache/outpost"

        sync.run("127.0.0.1", opts)

        assert.truthy(vim.wait(30000, function()
            return #notifications >= 2
        end))

        assert.equal(vim.log.levels.INFO, notifications[1].level)
        assert.equal(vim.log.levels.ERROR, notifications[2].level)
        assert.truthy(notifications[2].msg:find("Outpost update", 1, true))
        assert.equal(1, harness.remote("test -e $HOME/.cache/outpost/synced").code)
    end)
    it("pushes config and data into the outpost's XDG home and honors the floor", function()
        if not harness.pending_unless_up() then
            return
        end

        harness.remote "rm -f $HOME/.cache/outpost/synced"
        harness.remote "rm -rf $HOME/.cache/outpost/run"

        local result, err = unpack(await(up.run, 180000, "outpost@127.0.0.1:~/proj", opts))

        assert.truthy(result, err)

        -- a remote-owned zombie only --delete can remove
        harness.remote "mkdir -p $HOME/.cache/outpost/config/nvim && touch $HOME/.cache/outpost/config/nvim/zombie.txt"

        local config_root = vim.fn.tempname()
        local data_root = vim.fn.tempname()

        vim.fn.mkdir(config_root .. "/plugin", "p")
        vim.fn.mkdir(data_root .. "/lazy/one", "p")
        vim.fn.mkdir(data_root .. "/mason/bin", "p")
        vim.fn.mkdir(data_root .. "/outpost", "p")
        vim.fn.mkdir(data_root .. "/parser", "p")

        vim.fn.writefile({ "return 'canary'" }, config_root .. "/init.lua")
        vim.fn.writefile({ "plugin" }, data_root .. "/lazy/x.lua")
        vim.fn.writefile({ "lsp" }, data_root .. "/mason/bin/lsp")
        vim.fn.writefile({ "{}" }, data_root .. "/outpost/sessions.json")
        vim.fn.writefile({ "native" }, data_root .. "/parser/c.so")
        vim.uv.fs_symlink("/etc/hostname", config_root .. "/outside")

        local registry_before = table.concat(vim.fn.readfile(registry_dir .. "/sessions.json"), "\n")

        -- up.run already notified; the run's own notifications follow
        local at = #notifications

        sync.run(
            "127.0.0.1",
            vim.tbl_extend("force", opts, {
                config_root = config_root,
                data_root = data_root,
            })
        )

        assert.truthy(
            vim.wait(60000, function()
                return #notifications >= at + 2
            end),
            "sync never finished: "
                .. (#notifications > at and (notifications[#notifications].msg or "no message") or "no outcome")
        )

        assert.equal(
            vim.log.levels.INFO,
            notifications[at + 2].level,
            "expected success, got: " .. (notifications[at + 2] and notifications[at + 2].msg or "nothing")
        )
        assert.truthy(notifications[at + 1].msg:find("syncing 127.0.0.1", 1, true))

        assert.truthy(notifications[at + 2].msg:find("synced 127.0.0.1", 1, true))
        assert.truthy(notifications[at + 2].msg:find("files", 1, true))

        -- both trees landed under the outpost's XDG home
        assert.equal("return 'canary'", vim.trim(harness.remote("cat $HOME/.cache/outpost/config/nvim/init.lua").out))
        assert.equal("plugin", vim.trim(harness.remote("cat $HOME/.cache/outpost/data/nvim/lazy/x.lua").out))

        -- the marker stands only after a full sync
        assert.equal(0, harness.remote("test -e $HOME/.cache/outpost/synced").code)

        -- the exclusion floor: registry, mason, native artifacts
        assert.equal(1, harness.remote("test -d $HOME/.cache/outpost/data/nvim/mason").code)
        assert.equal(1, harness.remote("test -d $HOME/.cache/outpost/data/nvim/outpost").code)
        assert.equal("", vim.trim(harness.remote("find $HOME/.cache/outpost/data -name '*.so' 2>/dev/null").out))

        -- --delete removed the planted zombie
        assert.equal(1, harness.remote("test -e $HOME/.cache/outpost/config/nvim/zombie.txt").code)

        -- the 0700 roots
        assert.equal("700", vim.trim(harness.remote("stat -c '%a' $HOME/.cache/outpost/config").out))
        assert.equal("700", vim.trim(harness.remote("stat -c '%a' $HOME/.cache/outpost/data").out))

        -- the symlink was preserved as a link, never followed
        assert.equal(0, harness.remote("test -L $HOME/.cache/outpost/config/nvim/outside").code)

        -- the registry is untouched by sync
        assert.equal(registry_before, table.concat(vim.fn.readfile(registry_dir .. "/sessions.json"), "\n"))

        vim.fn.delete(config_root, "rf")
        vim.fn.delete(data_root, "rf")
    end)
    it("shows rsync's output in the failure float and leaves no marker", function()
        if not harness.pending_unless_up() then
            return
        end

        local installed, install_err = unpack(await(release.ensure, 180000, "outpost@127.0.0.1", opts))

        assert.truthy(installed, install_err)

        harness.remote "rm -f $HOME/.cache/outpost/synced"

        -- an unreadable source file: the sender fails loudly and nothing
        -- problematic lands remotely (unlike an unreadable directory, which
        -- rsync still creates before failing to descend into it)
        local config_root = vim.fn.tempname()

        vim.fn.mkdir(config_root, "p")
        vim.fn.writefile({ "return 'canary'" }, config_root .. "/init.lua")
        vim.fn.writefile({ "secret" }, config_root .. "/locked.txt")
        vim.uv.fs_chmod(config_root .. "/locked.txt", 0)

        local at = #notifications

        sync.run("127.0.0.1", vim.tbl_extend("force", opts, { config_root = config_root }))

        assert.truthy(
            vim.wait(60000, function()
                return #notifications >= at + 2
            end),
            "sync never finished"
        )

        assert.equal(vim.log.levels.ERROR, notifications[at + 2].level)
        assert.truthy(notifications[at + 2].msg:find("rsync failed", 1, true))
        assert.equal(1, harness.remote("test -e $HOME/.cache/outpost/synced").code)
        assert.stub(present.report).was_called()

        vim.uv.fs_chmod(config_root .. "/locked.txt", 420)
        vim.fn.delete(config_root, "rf")
    end)

    it("warns honestly when a session is live and leaves the server untouched", function()
        if not harness.pending_unless_up() then
            return
        end

        -- exactly one live session: drop any run/ left by earlier specs
        -- (their orphaned servers are invisible to a run/ scan)
        harness.remote "rm -rf $HOME/.cache/outpost/run"

        local started, start_err = unpack(await(up.run, 180000, "outpost@127.0.0.1:~/proj", opts))

        assert.truthy(started, start_err)

        local sid = started.session_id
        local pid_before = vim.trim(harness.remote(("cat %s"):format(session.paths(sid).pid)).out)

        assert.matches("^%d+$", pid_before)

        local config_root = vim.fn.tempname()
        local data_root = vim.fn.tempname()

        vim.fn.mkdir(config_root, "p")
        vim.fn.mkdir(data_root, "p")
        vim.fn.writefile({ "return 'canary'" }, config_root .. "/init.lua")

        local at = #notifications

        sync.run(
            "127.0.0.1",
            vim.tbl_extend("force", opts, {
                config_root = config_root,
                data_root = data_root,
            })
        )

        assert.truthy(
            vim.wait(60000, function()
                return #notifications >= at + 3
            end),
            "no honest warning: "
                .. vim.inspect(vim.tbl_map(function(entry)
                    return entry.msg
                end, notifications))
        )

        -- syncing, synced, then the honest warning naming the live count
        assert.equal(vim.log.levels.INFO, notifications[at + 2].level)
        assert.equal(vim.log.levels.WARN, notifications[at + 3].level)
        assert.truthy(notifications[at + 3].msg:find("1 live session(s) are running", 1, true))
        assert.truthy(notifications[at + 3].msg:find("may misbehave until restarted", 1, true))

        -- the running server was never restarted: same pid, still live
        assert.equal(pid_before, vim.trim(harness.remote(("cat %s"):format(session.paths(sid).pid)).out))
        assert.equal(0, harness.remote(("kill -0 %s"):format(pid_before)).code)

        local state = unpack(await(session.probe, nil, started.endpoint, sid, opts.conn))

        assert.equal("live", state and state.state)

        vim.fn.delete(config_root, "rf")
        vim.fn.delete(data_root, "rf")
    end)
end)
