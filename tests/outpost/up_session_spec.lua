-- Integration spec: `up` from a fresh outpost to a live session, end-to-end
-- against the docker-sshd fixture. Gated on the fixture being up. Drives
-- `up.run` - the function `:Outpost up` routes to - with fixture connection
-- details injected, and asserts observable state only: the per-session
-- directory and its contents, permission modes, probe-pattern observations
-- (cwd, environment), provisioning side effects, registry contents as data,
-- and what the user is told.

local up = require "outpost.up"
local session = require "outpost.session"

local harness = require "outpost.harness"
local await = require "outpost.await"

describe("up session start", function()
    local opts
    local registry_dir
    local cache_dir
    local client_dir
    local attach_dir

    before_each(function()
        if not harness.pending_unless_up() then
            return
        end

        registry_dir = vim.fn.tempname()
        vim.fn.mkdir(registry_dir, "p")

        -- one download cache for the whole spec (the archive is keyed by tag
        -- and platform, as it is in production); specs that must prove
        -- "nothing was downloaded" pass their own fresh directory.
        cache_dir = cache_dir or vim.fn.tempname()

        -- likewise one pinned-client cache for the whole spec
        client_dir = client_dir or vim.fn.tempname()
        attach_dir = vim.fn.tempname()

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

        harness.remote "mkdir -p $HOME/proj"
    end)

    after_each(function()
        if registry_dir then
            vim.fn.delete(registry_dir, "rf")
        end

        vim.fn.delete(attach_dir, "rf")
    end)

    it("takes a fresh outpost from nothing to a live session: socket, log, manifest, and provisioning", function()
        if not harness.pending_unless_up() then
            return
        end

        -- a fresh outpost: nothing installed, nothing minted, no sessions
        harness.remote "rm -rf $HOME/.cache/outpost"

        local reported = {}
        local real_notify = vim.notify

        vim.notify = function(msg, level)
            table.insert(reported, { msg = msg, level = level })
        end

        local result, err = unpack(await(up.run, 180000, "outpost@127.0.0.1:~/proj", opts))

        vim.notify = real_notify

        assert.truthy(result, err)

        local sid = result.session_id
        local paths = session.paths(sid)

        -- the session tree exists: socket, log, manifest
        assert.equal(0, harness.remote(("test -S %s"):format(paths.socket)).code)
        assert.equal(0, harness.remote(("test -f %s"):format(paths.log)).code)
        assert.equal(0, harness.remote(("test -f %s"):format(paths.manifest)).code)

        -- everything under the session tree is private (authority rule 7)
        local modes = harness.remote(("stat -c '%%a' %s %s"):format(paths.root, paths.socket))

        assert.equal("700\n600", vim.trim(modes.out))

        -- the manifest records what the remote scan needs
        local ok, manifest = pcall(vim.json.decode, vim.trim(harness.remote(("cat %s"):format(paths.manifest)).out))

        assert.truthy(ok, "manifest must be valid JSON")
        assert.equal("/home/outpost/proj", manifest.canonical_path)
        assert.equal("outpost@127.0.0.1", manifest.endpoint)
        assert.truthy(manifest.created > 0)

        -- provisioning ran: the portable install is recorded
        local version = harness.remote "cat $HOME/.cache/outpost/install/version"

        assert.equal(0, version.code)
        assert.matches("^v%d+", vim.trim(version.out))

        -- the provisioning sync ran too, and recorded its success on the
        -- outpost itself
        assert.equal(0, harness.remote("test -e $HOME/.cache/outpost/synced").code)

        -- the download landed in the injected cache, not the user's real cache
        assert.truthy(vim.uv.fs_stat(vim.fs.joinpath(cache_dir, "nvim-portable-" .. result.platform .. ".tar.gz")))

        -- cwd is the canonical project path, observable through the probe pattern
        local cwd, cwd_err = unpack(await(session.query, nil, result.endpoint, sid, "getcwd()", opts))

        assert.equal("/home/outpost/proj", cwd, "getcwd query failed: " .. tostring(cwd_err))

        -- the user is told the session started - no lossy-state language
        -- on a first start (there was nothing to lose)
        assert.truthy(reported[1], "up should notify the user")
        assert.equal(vim.log.levels.INFO, reported[1].level)
        assert.truthy(reported[1].msg:find(sid, 1, true), "notification names the session")
        assert.truthy(reported[1].msg:find("started session", 1, true))
        assert.falsy(reported[1].msg:find("lost", 1, true))

        -- the session is in the registry
        local registry = require "outpost.registry"
        local entry = registry.get(registry_dir, sid)

        assert.truthy(entry, "registry should hold an entry for the session")
        assert.equal("outpost@127.0.0.1", entry.endpoint)
        assert.equal("/home/outpost/proj", entry.canonical_path)
    end)

    it("relocates the session's XDG env but restores it for a process the session spawns", function()
        if not harness.pending_unless_up() then
            return
        end

        local first = await(up.run, 180000, "outpost@127.0.0.1:~/proj", opts)[1]

        assert.truthy(first)

        local sid = first.session_id

        -- the fixture account has no XDG vars of its own, so the account
        -- default for a spawned child is "unset" - system() runs the
        -- command through the session server, a real spawned child
        local child_xdg =
            unpack(await(session.query, nil, first.endpoint, sid, [[system('printenv XDG_CONFIG_HOME')]], opts))
        local child_session =
            unpack(await(session.query, nil, first.endpoint, sid, [[system('printenv OUTPOST_SESSION')]], opts))

        assert.equal(
            "",
            vim.trim(child_xdg),
            "a spawned child must see the account's default XDG env, not the outpost's"
        )
        assert.equal("", vim.trim(child_session), "a spawned child must not inherit OUTPOST_SESSION")
    end)

    it("re-running up against a healthy session is idempotent", function()
        if not harness.pending_unless_up() then
            return
        end

        -- ensure a live session (a no-op skip if the previous spec left one)
        local first, first_err = unpack(await(up.run, 180000, "outpost@127.0.0.1:~/proj", opts))

        assert.truthy(first, first_err)

        local sid = first.session_id
        local pid_before = await(session.query, nil, first.endpoint, sid, "getpid()", opts)[1]

        assert.matches("^%d+$", tostring(pid_before))

        -- a marker inside the installed tree: a re-provision would replace
        -- the tree and take the marker with it
        local current = vim.trim(harness.remote("readlink $HOME/.cache/outpost/install/current").out)
        local marker = ("$HOME/.cache/outpost/install/%s/.idempotence-marker"):format(current)

        harness.remote(("touch %s"):format(marker))

        -- the local cache is a fresh, empty directory: a re-download would
        -- have to create it
        local fresh_cache = vim.fn.tempname()
        local reported = {}
        local real_notify = vim.notify

        vim.notify = function(msg, level)
            table.insert(reported, { msg = msg, level = level })
        end

        local second, second_err = unpack(await(up.run, 60000, "outpost@127.0.0.1:~/proj", {
            conn = opts.conn,
            registry_dir = registry_dir,
            cache_dir = fresh_cache,
            client_dir = client_dir,
            attach_dir = attach_dir,
        }))

        vim.notify = real_notify

        assert.truthy(second, second_err)

        -- no second server: the same server answers, with the same pid
        local pid_after = await(session.query, nil, second.endpoint, sid, "getpid()", opts)[1]

        assert.equal(tostring(pid_before), tostring(pid_after))

        -- nothing was downloaded, re-provisioned, or re-pointed
        assert.falsy(vim.uv.fs_stat(fresh_cache), "re-up must not touch the download cache")
        assert.equal(0, harness.remote(("test -e %s"):format(marker)).code, "a re-provision would replace the tree")
        assert.equal(current, vim.trim(harness.remote("readlink $HOME/.cache/outpost/install/current").out))

        -- and the user is told it was a no-op
        assert.truthy(reported[1].msg:find("already live", 1, true))
        assert.truthy(reported[1].msg:find(sid, 1, true))
        assert.falsy(reported[1].msg:find("lost", 1, true))

        -- the registry entry is refreshed, and still names the session
        local registry = require "outpost.registry"
        local entry = registry.get(registry_dir, sid)

        assert.truthy(entry)
        assert.truthy(entry["last-used"] > 0)
    end)

    it("starts a fresh session after the server is killed, announcing the loss", function()
        if not harness.pending_unless_up() then
            return
        end

        -- ensure a live session
        local first = await(up.run, 180000, "outpost@127.0.0.1:~/proj", opts)[1]

        assert.truthy(first)

        local sid = first.session_id
        local paths = session.paths(sid)
        local old_pid = await(session.query, nil, first.endpoint, sid, "getpid()", opts)[1]

        assert.matches("^%d+$", tostring(old_pid))

        -- simulate a reboot: kill the server; the session directory and its
        -- manifest remain, so the loss is visible on the next up
        harness.remote(("kill %s"):format(old_pid))

        local state

        for _ = 1, 50 do
            state = await(session.probe, nil, first.endpoint, sid, opts.conn)[1]

            if state and state.state == "dead" then
                break
            end

            vim.wait(200)
        end

        assert.truthy(state and state.state == "dead", "the killed server should probe as dead")
        assert.truthy(state.remains, "the surviving manifest must mark the loss")

        local reported = {}
        local real_notify = vim.notify

        vim.notify = function(msg, level)
            table.insert(reported, { msg = msg, level = level })
        end

        local fresh_cache = vim.fn.tempname()
        local second, err = unpack(await(up.run, 120000, "outpost@127.0.0.1:~/proj", {
            conn = opts.conn,
            registry_dir = registry_dir,
            cache_dir = fresh_cache,
            client_dir = client_dir,
            attach_dir = attach_dir,
        }))

        vim.notify = real_notify

        assert.truthy(second, err)

        -- lossy state is announced,
        assert.truthy(reported[1], "up should notify the user")
        assert.truthy(reported[1].msg:find("fresh session", 1, true))
        assert.truthy(reported[1].msg:find("lost", 1, true))
        assert.truthy(reported[1].msg:find(sid, 1, true))
        assert.equal(vim.log.levels.WARN, reported[1].level)

        -- a fresh server answers: new pid
        local new_pid = await(session.query, nil, second.endpoint, sid, "getpid()", opts)[1]

        assert.matches("^%d+$", tostring(new_pid))
        assert.truthy(tostring(old_pid) ~= tostring(new_pid), "a fresh server must answer")

        -- the fresh session is still private
        assert.equal("600", vim.trim(harness.remote(("stat -c %%a %s"):format(paths.socket)).out))

        -- the recorded install was reused: nothing re-downloaded
        assert.falsy(vim.uv.fs_stat(fresh_cache))
    end)

    it("repairs a broken install instead of trusting its version record", function()
        if not harness.pending_unless_up() then
            return
        end

        -- ensure a live session
        local first = await(up.run, 180000, "outpost@127.0.0.1:~/proj", opts)[1]

        assert.truthy(first)

        local sid = first.session_id

        -- simulate a torn install (as a truncated transfer would leave it),
        -- and a dead server, so up has to decide whether to repair
        local pid = await(session.query, nil, first.endpoint, sid, "getpid()", opts)[1]

        harness.remote(("kill %s"):format(pid))
        harness.remote "rm -rf $HOME/.cache/outpost/install/current/lib"

        local state

        for _ = 1, 50 do
            state = await(session.probe, nil, first.endpoint, sid, opts.conn)[1]

            if state and state.state == "dead" then
                break
            end

            vim.wait(200)
        end

        assert.truthy(state and state.state == "dead")

        -- the version file is still there: a naive check would trust it
        assert.equal(0, harness.remote("test -s $HOME/.cache/outpost/install/version").code)
        assert.truthy(
            harness.remote("$HOME/.cache/outpost/install/current/bin/nvim --version >/dev/null 2>&1").code ~= 0,
            "the tree must be broken for this spec to mean anything"
        )

        local second, err = unpack(await(up.run, 180000, "outpost@127.0.0.1:~/proj", opts))

        assert.truthy(second, err)

        -- the install was repaired (the bundled nvim runs again)
        assert.equal(0, harness.remote("$HOME/.cache/outpost/install/current/bin/nvim --version >/dev/null 2>&1").code)

        -- and the session is live on the repaired tree
        local new_pid = await(session.query, nil, second.endpoint, sid, "getpid()", opts)[1]

        assert.matches("^%d+$", tostring(new_pid))
    end)

    it("loads the plugin in a session without an :Outpost command, from real boot-time config", function()
        if not harness.pending_unless_up() then
            return
        end

        -- a fresh outpost: no session, no config yet
        harness.remote "rm -rf $HOME/.cache/outpost $HOME/.session-mode-plugin $HOME/session-mode-result.txt"
        harness.remote "mkdir -p $HOME/.session-mode-plugin"

        local argv = { "scp" }

        vim.list_extend(argv, harness.scp_args())
        table.insert(argv, "-r")
        table.insert(argv, vim.fn.getcwd() .. "/lua")
        table.insert(argv, harness.target() .. ":.session-mode-plugin/")

        vim.fn.system(argv)

        assert.equal(0, vim.v.shell_error, "scp of the plugin tree to the fixture failed")

        -- the canary is the base's config: the provisioning sync carries it
        -- to the outpost, so the session server loads it for real at boot -
        -- the only moment OUTPOST_SESSION and the relocated XDG env are both
        -- still live (the post-config -c fragment restores them right after)
        local config_root = vim.fn.tempname()
        local data_root = vim.fn.tempname()

        vim.fn.mkdir(config_root, "p")
        vim.fn.mkdir(data_root, "p")

        local canary = {
            [[vim.g.outpost_session_canary = 'from-base']],
            [[vim.opt.rtp:prepend(os.getenv('HOME') .. '/.session-mode-plugin')]],
            [[local seen_session = vim.env.OUTPOST_SESSION]],
            [[local seen_config = vim.fn.stdpath('config')]],
            [[local seen_data = vim.fn.stdpath('data')]],
            [[require('outpost').setup()]],
            [[local f = io.open(os.getenv('HOME') .. '/session-mode-result.txt', 'w')]],
            [[f:write(table.concat({tostring(seen_session), seen_config, seen_data, tostring(vim.fn.exists(':Outpost'))}, '\n'))]],
            [[f:close()]],
        }

        vim.fn.writefile(canary, config_root .. "/init.lua")

        local live, live_err = unpack(
            await(
                up.run,
                180000,
                "outpost@127.0.0.1:~/proj",
                vim.tbl_extend("force", opts, { config_root = config_root, data_root = data_root })
            )
        )

        assert.truthy(live, live_err)

        local out = harness.remote "cat $HOME/session-mode-result.txt"

        harness.remote "rm -rf $HOME/.session-mode-plugin $HOME/.cache/outpost/config $HOME/session-mode-result.txt"

        vim.fn.delete(config_root, "rf")
        vim.fn.delete(data_root, "rf")

        assert.equal(0, out.code, "the canary config never ran")

        local lines = vim.split(vim.trim(out.out), "\n")

        assert.equal("1", lines[1], "setup() must see OUTPOST_SESSION=1 while config is loading")
        assert.equal(
            "/home/outpost/.cache/outpost/config/nvim",
            lines[2],
            "stdpath(config) must be outpost-owned at boot"
        )
        assert.equal("/home/outpost/.cache/outpost/data/nvim", lines[3], "stdpath(data) must be outpost-owned at boot")
        assert.equal("0", lines[4], "session mode must register no :Outpost command")

        -- the fresh host's first up left the marker behind . . .
        assert.equal(0, harness.remote("test -e $HOME/.cache/outpost/synced").code)

        -- . . . and the running session booted the base's config, not an
        -- empty or leftover one
        local canary_value =
            await(session.query, nil, live.endpoint, live.session_id, "g:outpost_session_canary", opts)[1]

        assert.equal("from-base", canary_value)
    end)
end)
