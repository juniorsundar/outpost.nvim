-- Integration spec: `sync.run` end-to-end against the docker-sshd fixture -
-- the trees land under the outpost's XDG home, the marker exists, the
-- exclusion floor holds, --delete removes remote-only material, and the
-- roots stay private. Gated on the fixture being up.

local config = require "outpost.config"
local registry = require "outpost.registry"
local release = require "outpost.release"
local session = require "outpost.session"
local sync = require "outpost.sync"
local up = require "outpost.up"

local harness = require "outpost.harness"
local await = require "outpost.await"

local stub = require "luassert.stub"

-- The per-operation view handle the specs inject through opts.progress:
-- phases, streams, and the outcome all land on it, nothing on globals.
local function recording_handle()
    local handle = {
        phases = {},
        chunks = {},
        opened = 0,
        succeeded = false,
        failed = false,
    }

    function handle:phase(text)
        table.insert(self.phases, text)
    end

    function handle:open()
        self.opened = self.opened + 1
    end

    function handle:stream(chunk, source)
        table.insert(self.chunks, { chunk = chunk, source = source })
    end

    function handle:succeed()
        self.succeeded = true
    end

    function handle:fail()
        self.failed = true
    end

    function handle:streamed()
        local joined = {}

        for _, entry in ipairs(self.chunks) do
            table.insert(joined, entry.chunk)
        end

        return table.concat(joined)
    end

    return handle
end

describe("sync run", function()
    local registry_dir
    local cache_dir
    local client_dir
    local opts

    local real_notify
    local notifications
    local ui_stub
    local cleanup_win
    local cleanup_dirs

    -- The real handle needs a UI to exist; the integration runner is headless.
    local function pretend_ui()
        ui_stub = stub(vim.api, "nvim_list_uis").returns { { focusable = true } }
    end

    -- The view's window: whatever appeared beyond a baseline window set.
    local function window_set()
        local set = {}

        for _, win in ipairs(vim.api.nvim_list_wins()) do
            set[win] = true
        end

        return set
    end

    local function new_window(baseline)
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            if not baseline[win] then
                return win
            end
        end

        return nil
    end

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

        harness.remote "mkdir -p $HOME/proj"
    end)

    after_each(function()
        if real_notify then
            vim.notify = real_notify
        end

        config.setup {}

        if ui_stub then
            ui_stub:revert()
            ui_stub = nil
        end

        if cleanup_win and vim.api.nvim_win_is_valid(cleanup_win) then
            vim.api.nvim_win_close(cleanup_win, true)
        end

        cleanup_win = nil

        for _, dir in ipairs(cleanup_dirs or {}) do
            vim.fn.delete(dir, "rf")
        end

        cleanup_dirs = nil

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

        local handle = recording_handle()

        sync.run(
            "127.0.0.1",
            vim.tbl_extend("force", opts, {
                config_root = config_root,
                data_root = data_root,
                progress = function()
                    return handle
                end,
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

        -- the view streamed the whole ladder: one phase per step, the window
        -- materialized once at the transfer, and the real rsync stats rode
        -- the stream seam
        assert.truthy(handle.succeeded, "the view auto-closes on success")
        assert.equal(1, handle.opened)
        assert.are_same(
            { "probing the outpost", "syncing the config tree", "syncing the data tree", "writing the sync marker" },
            handle.phases
        )
        assert.truthy(handle:streamed():find("Total transferred file size", 1, true))

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
    it("never lands a user-excluded path while the floor still holds", function()
        if not harness.pending_unless_up() then
            return
        end

        local installed, install_err = unpack(await(release.ensure, 180000, "outpost@127.0.0.1", opts))

        assert.truthy(installed, install_err)

        harness.remote "rm -f $HOME/.cache/outpost/synced"

        local config_root = vim.fn.tempname()
        local data_root = vim.fn.tempname()

        vim.fn.mkdir(config_root .. "/scratch", "p")
        vim.fn.mkdir(data_root .. "/scratch", "p")
        vim.fn.mkdir(data_root .. "/outpost", "p")
        vim.fn.writefile({ "return 'canary'" }, config_root .. "/init.lua")
        vim.fn.writefile({ "private" }, config_root .. "/scratch/notes.md")
        vim.fn.writefile({ "private" }, data_root .. "/scratch/blob.bin")
        vim.fn.writefile({ "{}" }, data_root .. "/outpost/sessions.json")

        config.setup { sync = { exclude = { "scratch/" } } }

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
            "sync never finished"
        )

        assert.equal(vim.log.levels.INFO, notifications[at + 2].level)
        assert.equal("return 'canary'", vim.trim(harness.remote("cat $HOME/.cache/outpost/config/nvim/init.lua").out))

        -- the one pattern is hidden from both roots
        assert.equal(1, harness.remote("test -e $HOME/.cache/outpost/config/nvim/scratch/notes.md").code)
        assert.equal(1, harness.remote("test -e $HOME/.cache/outpost/data/nvim/scratch/blob.bin").code)

        -- the floor member still never lands
        assert.equal(1, harness.remote("test -d $HOME/.cache/outpost/data/nvim/outpost").code)

        vim.fn.delete(config_root, "rf")
        vim.fn.delete(data_root, "rf")
    end)

    it("keeps the view on failure with rsync's real output streamed, and leaves no marker", function()
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

        local handle = recording_handle()

        sync.run(
            "127.0.0.1",
            vim.tbl_extend("force", opts, {
                config_root = config_root,
                progress = function()
                    return handle
                end,
            })
        )

        assert.truthy(
            vim.wait(60000, function()
                return #notifications >= at + 2
            end),
            "sync never finished"
        )

        assert.equal(vim.log.levels.ERROR, notifications[at + 2].level)
        assert.truthy(notifications[at + 2].msg:find("rsync failed", 1, true))
        assert.equal(1, harness.remote("test -e $HOME/.cache/outpost/synced").code)

        -- the view stays open with rsync's output streamed; no float, no
        -- success lifecycle
        assert.truthy(handle.failed, "the view stays on failure")
        assert.falsy(handle.succeeded)
        assert.truthy(handle.opened >= 1, "the transfer phase materialized the window")
        assert.truthy(handle:streamed():find("locked.txt", 1, true))

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

    it("holds a real window open for the live transfer and closes it on success", function()
        if not harness.pending_unless_up() then
            return
        end

        local installed, install_err = unpack(await(release.ensure, 180000, "outpost@127.0.0.1", opts))

        assert.truthy(installed, install_err)

        harness.remote "rm -f $HOME/.cache/outpost/synced"

        pretend_ui()

        -- enough files that the transfer outlasts the observation loop
        local config_root = vim.fn.tempname()
        local data_root = vim.fn.tempname()

        cleanup_dirs = { config_root, data_root }

        vim.fn.mkdir(config_root .. "/bulk", "p")
        vim.fn.mkdir(data_root .. "/lazy", "p")
        vim.fn.writefile({ "return 'canary'" }, config_root .. "/init.lua")
        vim.fn.writefile({ "plugin" }, data_root .. "/lazy/x.lua")

        for i = 1, 800 do
            vim.fn.writefile({ "payload " .. i }, ("%s/bulk/f%04d"):format(config_root, i))
        end

        local baseline = window_set()
        local baseline_count = #vim.api.nvim_list_wins()
        local at = #notifications

        sync.run(
            "127.0.0.1",
            vim.tbl_extend("force", opts, {
                config_root = config_root,
                data_root = data_root,
            })
        )

        -- the window materializes while the transfer still runs
        local win, buf

        assert.truthy(
            vim.wait(60000, function()
                local candidate = new_window(baseline)

                if not candidate then
                    return false
                end

                buf = vim.api.nvim_win_get_buf(candidate)
                local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")

                if text:find("syncing the config tree", 1, true) then
                    win = candidate
                    return true
                end

                return false
            end, 5),
            "no window ever carried the transfer's phase line"
        )

        -- observed mid-operation: the syncing announcement, no outcome yet
        cleanup_win = win

        assert.equal(at + 1, #notifications, "the window must be caught while the operation still runs")
        assert.truthy(win and vim.api.nvim_win_is_valid(win))
        assert.equal(buf, vim.api.nvim_win_get_buf(win))

        assert.truthy(
            vim.wait(60000, function()
                return #notifications >= at + 2
            end),
            "the transfer never finished"
        )

        assert.equal(vim.log.levels.INFO, notifications[at + 2].level)
        assert.truthy(notifications[at + 2].msg:find("synced 127.0.0.1", 1, true))

        -- success closes the window and wipes its buffer
        assert.falsy(vim.api.nvim_win_is_valid(win), "the window must close on success")
        assert.falsy(vim.api.nvim_buf_is_valid(buf), "success leaves no buffer debris")
        assert.equal(baseline_count, #vim.api.nvim_list_wins())
    end)

    it("keeps the window open, focused, with rsync's real output on failure", function()
        if not harness.pending_unless_up() then
            return
        end

        local installed, install_err = unpack(await(release.ensure, 180000, "outpost@127.0.0.1", opts))

        assert.truthy(installed, install_err)

        harness.remote "rm -f $HOME/.cache/outpost/synced"

        pretend_ui()

        local config_root = vim.fn.tempname()

        cleanup_dirs = { config_root }

        vim.fn.mkdir(config_root, "p")
        vim.fn.writefile({ "return 'canary'" }, config_root .. "/init.lua")
        vim.fn.writefile({ "secret" }, config_root .. "/locked.txt")
        vim.uv.fs_chmod(config_root .. "/locked.txt", 0)

        local baseline = window_set()
        local at = #notifications

        sync.run("127.0.0.1", vim.tbl_extend("force", opts, { config_root = config_root }))

        assert.truthy(
            vim.wait(60000, function()
                return #notifications >= at + 2
            end),
            "the failing sync never finished"
        )

        assert.equal(vim.log.levels.ERROR, notifications[at + 2].level)
        assert.truthy(notifications[at + 2].msg:find("rsync failed", 1, true))

        local win = new_window(baseline)

        cleanup_win = win

        assert.truthy(win and vim.api.nvim_win_is_valid(win), "the window must persist on failure")
        assert.equal(win, vim.api.nvim_get_current_win(), "the window must take focus on failure")

        local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")

        assert.truthy(text:find("locked.txt", 1, true), "rsync's real output must be readable in the window")
    end)
end)
