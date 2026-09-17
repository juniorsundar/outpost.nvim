-- Unit spec for the sync module's pure builders (offline: no network, no
-- stubs - the command/argv contracts are the module interface).

local config = require "outpost.config"
local present = require "outpost.present"
local registry = require "outpost.registry"
local sync = require "outpost.sync"

-- A recording handle: every view interaction lands in one ordered event list.
local function recording_view()
    local events = {}

    return {
        events = events,
        phase = function(_, text)
            table.insert(events, { kind = "phase", text = text })
        end,
        open = function(_)
            table.insert(events, { kind = "open" })
        end,
        stream = function(_, chunk, source)
            table.insert(events, { kind = "stream", chunk = chunk, source = source })
        end,
        succeed = function(_)
            table.insert(events, { kind = "succeed" })
        end,
        fail = function(_)
            table.insert(events, { kind = "fail" })
        end,
    }
end

describe("sync gate command", function()
    local command = sync.build_gate_command()

    it("refuses a missing outpost before probing rsync", function()
        local no_outpost_at = command:find("no outpost", 1, true)
        local rsync_at = command:find("install/current/bin/rsync", 1, true)

        assert.truthy(rsync_at, "must name the bundled rsync")
        assert.truthy(no_outpost_at and no_outpost_at < rsync_at)
    end)

    it("distinguishes a missing outpost from a missing bundled rsync", function()
        assert.truthy(command:find("outpost-sync-gate-failed: no outpost", 1, true))
        assert.truthy(command:find("outpost-sync-gate-failed: no bundled rsync", 1, true))
    end)

    it("probes the bundled rsync's executability at install/current/bin", function()
        assert.truthy(command:find("install/current/bin/rsync", 1, true))
        assert.truthy(command:find('[ ! -x "$RSYNC" ]', 1, true))
    end)

    it("pre-creates the config and data roots with mode 0700", function()
        assert.truthy(command:find("mkdir -p -m 700", 1, true))
        assert.truthy(command:find("chmod 700", 1, true))
        assert.truthy(command:find('"$OUTPOST/config"', 1, true))
        assert.truthy(command:find('"$OUTPOST/data"', 1, true))
    end)

    it("prints the account's absolute home directory", function()
        assert.truthy(command:find("printf '%s\\n' \"$HOME\"", 1, true))
    end)
end)

describe("sync gate command is valid POSIX sh", function()
    it("parses with sh -n", function()
        local path = vim.fn.tempname() .. ".sh"

        vim.fn.writefile(vim.split(sync.build_gate_command(), "\n"), path)
        vim.fn.system { "sh", "-n", path }

        local code = vim.v.shell_error

        vim.fn.delete(path)

        assert.equal(0, code)
    end)
end)

describe("sync gate output", function()
    it("reads the absolute home from the probe's output", function()
        assert.equal("/home/outpost", sync.parse_gate_output "/home/outpost\n")
    end)

    it("rejects empty output", function()
        assert.is_nil(sync.parse_gate_output "")
        assert.is_nil(sync.parse_gate_output "\n")
        assert.is_nil(sync.parse_gate_output(nil))
    end)

    it("rejects a non-absolute home - --rsync-path would be garbage", function()
        assert.is_nil(sync.parse_gate_output "home/outpost\n")
    end)
end)

local transport = require "outpost.transport"

describe("sync remote destination", function()
    it("lands the tree under the outpost's XDG home", function()
        assert.equal(
            "outpost@box:/home/o/.cache/outpost/config/nvim/",
            sync.remote_dest("outpost@box", "/home/o", "config")
        )
        assert.equal(
            "outpost@box:/home/o/.cache/outpost/data/nvim/",
            sync.remote_dest("outpost@box", "/home/o", "data")
        )
    end)
end)

describe("sync exclusion floor", function()
    it("hides the mandatory floor members from the transfer", function()
        local filters = sync.exclude_filters()

        local floor = { "H outpost/", "H mason/", "H *.so" }

        assert.equal(#floor * 2, #filters)

        for index, rule in ipairs(floor) do
            assert.equal("-f", filters[(index - 1) * 2 + 1])
            assert.equal(rule, filters[index * 2])
        end
    end)

    it("uses hide rules only - nothing is protected from --delete", function()
        for _, value in ipairs(sync.exclude_filters { "node_modules/" }) do
            if value ~= "-f" then
                assert.equal("H ", value:sub(1, 2))
            end
        end
    end)

    it("appends user patterns after the floor, in order", function()
        local filters = sync.exclude_filters { "node_modules/", "*.log" }

        local floor = { "H outpost/", "H mason/", "H *.so" }

        for index, rule in ipairs(floor) do
            assert.equal("-f", filters[(index - 1) * 2 + 1])
            assert.equal(rule, filters[index * 2])
        end

        assert.equal("-f", filters[#floor * 2 + 1])
        assert.equal("H node_modules/", filters[#floor * 2 + 2])
        assert.equal("-f", filters[#floor * 2 + 3])
        assert.equal("H *.log", filters[#floor * 2 + 4])
    end)

    it("never lets a user pattern unhide or replace the floor", function()
        local filters = sync.exclude_filters { "+ outpost/", "outpost/", "mason/", "*.so" }

        for index, value in ipairs(filters) do
            if value ~= "-f" then
                assert.equal("H ", value:sub(1, 2), "only hide rules may be emitted")
            end
        end

        assert.equal("H outpost/", filters[2])
        assert.equal("H mason/", filters[4])
        assert.equal("H *.so", filters[6])
    end)

    it("ignores empty and non-string user patterns", function()
        local filters = sync.exclude_filters { "", "keep/", false, 42 }

        assert.equal("H keep/", filters[#filters])
        assert.equal(8, #filters)
    end)
end)

describe("sync rsync argv", function()
    local conn = {
        port = "2222",
        key = "/keys/ed25519",
        known_hosts = "/keys/known_hosts",
    }
    local source = "/base/.config/nvim/"
    local dest = "outpost@box:/home/o/.cache/outpost/config/nvim/"

    local function argv_for(source_root, dest_root, home, connection, user_excludes)
        return sync.build_rsync_argv(source_root, dest_root, home, connection, user_excludes)
    end

    local function position(argv_list, value)
        for index, item in ipairs(argv_list) do
            if item == value then
                return index
            end
        end
    end

    local argv = argv_for(source, dest, "/home/o", conn)

    it("is an rsync invocation of the source into the destination", function()
        assert.equal("rsync", argv[1])
        assert.equal(source, argv[#argv - 1])
        assert.equal(dest, argv[#argv])
    end)

    it("archives without uid/gid ownership", function()
        assert.truthy(position(argv, "-a"))
        assert.truthy(position(argv, "--no-owner"))
        assert.truthy(position(argv, "--no-group"))
    end)

    it("deletes remote-only files but never its own exclusions", function()
        assert.truthy(position(argv, "--delete"))
        assert.is_nil(position(argv, "--delete-excluded"))
    end)

    it("reports per-invocation stats for the aggregate", function()
        assert.truthy(position(argv, "--stats"))
    end)

    it("emits the aggregate progress line without dropping the stats", function()
        assert.truthy(position(argv, "--info=progress2"))
        assert.truthy(position(argv, "--stats"))
    end)

    it("skips device and special files", function()
        assert.truthy(position(argv, "--no-D"))
    end)

    it("carries the exclusion floor as hide-only filter rules", function()
        for index, item in ipairs(argv) do
            if item == "-f" then
                assert.equal("H ", argv[index + 1]:sub(1, 2))
            end
        end

        assert.truthy(position(argv, "H outpost/"))
        assert.truthy(position(argv, "H mason/"))
        assert.truthy(position(argv, "H *.so"))
    end)

    it("appends user excludes after the floor", function()
        local with_user = argv_for(source, dest, "/home/o", conn, { "node_modules/" })
        local floor_at = position(with_user, "H *.so")
        local user_at = position(with_user, "H node_modules/")

        assert.truthy(floor_at)
        assert.truthy(user_at)
        assert.truthy(floor_at < user_at)
    end)

    it("never follows symlinks", function()
        assert.is_nil(position(argv, "-L"))
        assert.is_nil(position(argv, "--copy-links"))
        assert.is_nil(position(argv, "--copy-dirlinks"))
        assert.is_nil(position(argv, "--keep-dirlinks"))
    end)

    it("rides the same shell-quoted transport options as ssh and scp", function()
        local e = position(argv, "-e")
        local expected = {}

        for _, arg in ipairs(transport.ssh_args(conn)) do
            table.insert(expected, "'" .. arg .. "'")
        end

        assert.truthy(e, "-e must be present")
        assert.equal("ssh " .. table.concat(expected, " "), argv[e + 1])
    end)

    it("runs the remote side through the bundled rsync at the absolute home", function()
        local path = position(argv, "--rsync-path='/home/o/.cache/outpost/install/current/bin/rsync'")

        assert.truthy(path, "--rsync-path must name the bundled rsync by absolute home")
    end)

    it("carries mux options on -e for a muxed host", function()
        local mux_conn = { mux = true, mux_path = "/tmp/mux/%C" }
        local mux_argv = argv_for(source, dest, "/home/o", mux_conn)
        local e = position(mux_argv, "-e")

        assert.truthy(e)
        assert.truthy(mux_argv[e + 1]:find("'ControlPath=/tmp/mux/%C'", 1, true))
    end)

    it("quotes a control path containing spaces", function()
        local mux_conn = { mux = true, mux_path = "/tmp/cache with space/%C" }
        local mux_argv = argv_for(source, dest, "/home/o", mux_conn)
        local e = position(mux_argv, "-e")

        assert.truthy(mux_argv[e + 1]:find("'ControlPath=/tmp/cache with space/%C'", 1, true))
    end)
end)

describe("sync marker command", function()
    local command = sync.build_marker_command()

    it("writes the sync marker inside the outpost root", function()
        assert.truthy(command:find(".cache/outpost/synced", 1, true))
    end)

    it("parses with sh -n", function()
        local path = vim.fn.tempname() .. ".sh"

        vim.fn.writefile(vim.split(command, "\n"), path)
        vim.fn.system { "sh", "-n", path }

        local code = vim.v.shell_error

        vim.fn.delete(path)

        assert.equal(0, code)
    end)
end)

describe("sync marker probe", function()
    local command = sync.build_marker_probe_command()

    it("reads the marker the successful sync writes", function()
        assert.truthy(command:find(".cache/outpost/synced", 1, true))
        assert.truthy(command:find("synced", 1, true))
    end)

    it("parses with sh -n", function()
        local path = vim.fn.tempname() .. ".sh"

        vim.fn.writefile(vim.split(command, "\n"), path)
        vim.fn.system { "sh", "-n", path }

        local code = vim.v.shell_error

        vim.fn.delete(path)

        assert.equal(0, code)
    end)
end)

describe("sync marker presence", function()
    -- Drives sync.has_marker with an injected transport; the runner's
    -- callback is synchronous.
    local function probe(output, code)
        local result, err

        sync.has_marker("outpost@box", {
            transport = {
                run = function(_, _, _, callback)
                    callback(code or 0, output, nil)
                end,
            },
        }, function(synced, probe_err)
            result, err = synced, probe_err
        end)

        return result, err
    end

    it("reports a standing marker as synced", function()
        local synced, err = probe "synced\n"

        assert.is_true(synced)
        assert.is_nil(err)
    end)

    it("reports a missing marker as unsynced", function()
        local synced, err = probe "unsynced\n"

        assert.is_false(synced)
        assert.is_nil(err)
    end)

    it("errors when the probe round trip fails", function()
        local synced, err = probe(nil, 255)

        assert.is_nil(synced)
        assert.truthy(err)
    end)
end)

describe("sync stats", function()
    local stats_output = table.concat({
        "Number of files: 5 (reg: 3, dir: 2)",
        "Number of regular files transferred: 3",
        "Total transferred file size: 1,654 bytes",
        "sent 234 bytes  received 56 bytes",
    }, "\n")

    it("parses the transferred file count and size from --stats output", function()
        assert.are_same({ files = 3, bytes = 1654 }, sync.parse_stats(stats_output))
    end)

    it("tolerates unparseable output", function()
        assert.is_nil(sync.parse_stats "rsync error: connection dropped")
        assert.is_nil(sync.parse_stats(nil))
    end)

    it("aggregates the two invocations' stats", function()
        local aggregate = sync.aggregate_stats({ files = 3, bytes = 1654 }, { files = 9, bytes = 44032 })

        assert.are_same({ files = 12, bytes = 45686 }, aggregate)
    end)

    it("keeps no aggregate when an invocation's stats are unreadable", function()
        assert.is_nil(sync.aggregate_stats({ files = 3, bytes = 100 }, nil))
    end)
end)

describe("sync flow", function()
    local endpoint = "outpost@box"
    local conn = { port = "2222" }
    local STATS = "Number of regular files transferred: 3\nTotal transferred file size: 1,654 bytes\n"

    after_each(function()
        config.setup {}
    end)

    -- Drives sync.sync with injected collaborators and records every
    -- remote step as { kind = "gate"|"marker", command } or
    -- { kind = "rsync", argv }.
    local function drive(rsync_result, gate_out, gate_code)
        local calls = {}

        local opts = {
            conn = conn,
            executable = function()
                return 1
            end,
            config_root = "/base/cfg",
            data_root = "/base/dat",
            transport = {
                run = function(_, command, _, callback)
                    local kind = command:find("synced", 1, true) and "marker" or "gate"

                    table.insert(calls, { kind = kind, command = command })

                    if kind == "marker" then
                        callback(0, "", nil)
                    else
                        callback(gate_code or 0, gate_out or "/home/o\n", nil)
                    end
                end,
            },
            rsync = function(argv, callback)
                table.insert(calls, { kind = "rsync", argv = argv })
                callback(rsync_result or { code = 0, stdout = STATS, stderr = "" })
            end,
        }

        return calls, opts
    end

    it("errors before any ssh round trip when the base has no rsync", function()
        local calls = {}
        local result, err

        sync.sync(endpoint, {
            conn = conn,
            executable = function()
                return 0
            end,
            transport = {
                run = function()
                    table.insert(calls, "ssh")
                end,
            },
        }, function(...)
            result, err = ...
        end)

        assert.is_nil(result)
        assert.truthy(err:find("rsync", 1, true))
        assert.equal(0, #calls, "no ssh round trip may happen")
    end)

    it("points at :Outpost up when the outpost is missing", function()
        local result, err

        local _, opts = drive(nil, "outpost-sync-gate-failed: no outpost\n", 1)

        sync.sync(endpoint, opts, function(...)
            result, err = ...
        end)

        assert.is_nil(result)
        assert.truthy(err:find("Outpost up", 1, true))
    end)

    it("points at :Outpost update when the bundled rsync is missing", function()
        local result, err

        local _, opts = drive(nil, "outpost-sync-gate-failed: no bundled rsync\n", 1)

        sync.sync(endpoint, opts, function(...)
            result, err = ...
        end)

        assert.is_nil(result)
        assert.truthy(err:find("Outpost update", 1, true))
    end)

    it("gates, syncs config then data, then writes the marker", function()
        local calls, opts = drive()
        local result, err

        sync.sync(endpoint, opts, function(...)
            result, err = ...
        end)

        assert.truthy(result, err)

        local kinds = {}

        for index, call in ipairs(calls) do
            kinds[index] = call.kind
        end

        assert.are_same({ "gate", "rsync", "rsync", "marker" }, kinds)
    end)

    it("syncs the injected roots into the outpost's XDG home", function()
        local calls, opts = drive()

        sync.sync(endpoint, opts, function() end)

        assert.equal("/base/cfg/", calls[2].argv[#calls[2].argv - 1])
        assert.equal(endpoint .. ":/home/o/.cache/outpost/config/nvim/", calls[2].argv[#calls[2].argv])
        assert.equal("/base/dat/", calls[3].argv[#calls[3].argv - 1])
        assert.equal(endpoint .. ":/home/o/.cache/outpost/data/nvim/", calls[3].argv[#calls[3].argv])
    end)

    it("defaults the roots to the base's own stdpath trees", function()
        local calls = {}

        local _, opts = drive()

        opts.config_root = nil
        opts.data_root = nil
        opts.rsync = function(argv, callback)
            table.insert(calls, argv)
            callback { code = 0, stdout = STATS, stderr = "" }
        end

        sync.sync(endpoint, opts, function() end)

        assert.equal(vim.fn.stdpath "config" .. "/", calls[1][#calls[1] - 1])
        assert.equal(vim.fn.stdpath "data" .. "/", calls[2][#calls[2] - 1])
    end)

    it("reports the aggregate stats of both invocations", function()
        local result

        local _, opts = drive()

        sync.sync(endpoint, opts, function(res)
            result = res
        end)

        assert.are_same({ files = 6, bytes = 3308 }, result.stats)
    end)

    it("aborts before the marker when the first rsync fails", function()
        local calls, opts = drive { code = 23, stdout = "boom-out", stderr = "boom-err" }
        local result, err, detail

        sync.sync(endpoint, opts, function(res, e, d)
            result, err, detail = res, e, d
        end)

        assert.is_nil(result)
        assert.truthy(err)
        assert.truthy(detail:find("boom-out", 1, true))
        assert.equal(2, #calls, "no second rsync, no marker")
    end)

    it("aborts before the marker when the second rsync fails", function()
        local calls = {}
        local first = true

        local opts = {
            conn = conn,
            executable = function()
                return 1
            end,
            config_root = "/base/cfg",
            data_root = "/base/dat",
            transport = {
                run = function(_, command, _, callback)
                    table.insert(calls, command:find("synced", 1, true) and "marker" or "gate")
                    callback(0, "/home/o\n", nil)
                end,
            },
            rsync = function(_, callback)
                table.insert(calls, "rsync")

                if first then
                    first = false
                    callback { code = 0, stdout = STATS, stderr = "" }
                else
                    callback { code = 23, stdout = "late-boom", stderr = "" }
                end
            end,
        }

        local result, err

        sync.sync(endpoint, opts, function(res, e)
            result, err = res, e
        end)

        assert.is_nil(result)
        assert.truthy(err)
        assert.are_same({ "gate", "rsync", "rsync" }, calls, "no marker after a failed data rsync")
    end)

    it("aborts without any rsync when the gate fails", function()
        local calls, opts = drive(nil, "outpost-sync-gate-failed: no outpost\n", 1)

        sync.sync(endpoint, opts, function() end)

        assert.equal(1, #calls)
    end)

    it("passes user excludes to both rsync invocations", function()
        local calls, opts = drive()

        opts.exclude = { "scratch/" }

        sync.sync(endpoint, opts, function() end)

        for _, call in ipairs(calls) do
            if call.kind == "rsync" then
                local found = false

                for _, item in ipairs(call.argv) do
                    found = found or item == "H scratch/"
                end

                assert.truthy(found, "user exclude missing from the argv")
            end
        end
    end)

    it("draws user excludes from setup when the caller passes none", function()
        local calls, opts = drive()

        config.setup { sync = { exclude = { "from-setup/" } } }

        sync.sync(endpoint, opts, function() end)

        for _, call in ipairs(calls) do
            if call.kind == "rsync" then
                local found = false

                for _, item in ipairs(call.argv) do
                    found = found or item == "H from-setup/"
                end

                assert.truthy(found, "setup exclude missing from the argv")
            end
        end
    end)

    it("creates the mux socket directory before transferring", function()
        local ensured = false

        local opts = {
            conn = { mux = true, mux_path = "/tmp/nowhere/%C" },
            executable = function()
                return 1
            end,
            config_root = "/base/cfg",
            data_root = "/base/dat",
            transport = {
                ensure_mux_dir = function(conn)
                    ensured = conn
                end,
                run = function(_, _, _, callback)
                    callback(0, "/home/o\n", nil)
                end,
            },
            rsync = function(_, callback)
                callback { code = 0, stdout = STATS, stderr = "" }
            end,
        }

        sync.sync(endpoint, opts, function() end)

        assert.equal(opts.conn, ensured)
    end)
end)

describe("sync live count", function()
    local endpoint = "outpost@box"

    -- Drives live_count with injected scan/probe; the callbacks are
    -- synchronous, as in the flow spec.
    local function drive(entries, states, scan_err)
        local count

        sync.live_count(endpoint, {
            scan = function(_, _, callback)
                callback(entries, scan_err)
            end,
            probe = function(_, session_id, _, callback)
                callback(states and states[session_id])
            end,
        }, function(n)
            count = n
        end)

        return count
    end

    it("counts only the live sessions among the run entries", function()
        local count = drive({ { session_id = "aaaaaa" }, { session_id = "bbbbbb" }, { session_id = "cccccc" } }, {
            aaaaaa = { state = "live" },
            bbbbbb = { state = "dead" },
            cccccc = { state = "live" },
        })

        assert.equal(2, count)
    end)

    it("counts zero when the outpost has no run entries", function()
        assert.equal(0, drive({}, {}))
    end)

    it("counts zero when the scan fails - the warning is advisory", function()
        assert.equal(0, drive(nil, nil, "scan failed"))
    end)

    it("counts zero when every probe is unreachable", function()
        assert.equal(0, drive({ { session_id = "aaaaaa" } }, { aaaaaa = nil }))
    end)
end)

describe("sync progress view", function()
    local endpoint = "outpost@box"
    local conn = { port = "2222" }
    local STATS = "Number of regular files transferred: 3\nTotal transferred file size: 1,654 bytes\n"

    -- Drives sync.sync with the injected view recording its steps alongside
    -- the remote/rsync calls they precede.
    local function drive(rsync_result, gate_out, gate_code)
        local handle = recording_view()

        local opts = {
            conn = conn,
            view = handle,
            executable = function()
                return 1
            end,
            config_root = "/base/cfg",
            data_root = "/base/dat",
            transport = {
                run = function(_, command, _, callback)
                    table.insert(handle.events, { kind = command:find("synced", 1, true) and "marker" or "gate" })

                    if command:find("synced", 1, true) then
                        callback(0, "", nil)
                    else
                        callback(gate_code or 0, gate_out or "/home/o\n", nil)
                    end
                end,
            },
            rsync = function(argv, callback, on_chunk)
                table.insert(handle.events, { kind = "rsync", argv = argv, on_chunk = on_chunk })
                callback(rsync_result or { code = 0, stdout = STATS, stderr = "" })
            end,
        }

        return handle, opts
    end

    local function kinds(handle)
        local names = {}

        for _, event in ipairs(handle.events) do
            names[#names + 1] = event.text and (event.kind .. ": " .. event.text) or event.kind
        end

        return names
    end

    it("announces one phase line per phase, in ladder order", function()
        local handle, opts = drive()

        sync.sync(endpoint, opts, function() end)

        local phases = {}

        for _, event in ipairs(handle.events) do
            if event.kind == "phase" then
                table.insert(phases, event.text)
            end
        end

        assert.are_same(
            { "probing the outpost", "syncing the config tree", "syncing the data tree", "writing the sync marker" },
            phases
        )
    end)

    it("opens the window once, at the first transfer, never at the gate or the marker", function()
        local handle, opts = drive()

        sync.sync(endpoint, opts, function() end)

        assert.are_same({
            "phase: probing the outpost",
            "gate",
            "open",
            "phase: syncing the config tree",
            "rsync",
            "phase: syncing the data tree",
            "rsync",
            "phase: writing the sync marker",
            "marker",
        }, kinds(handle))
    end)

    it("opens nothing on its own when the gate refuses the sync", function()
        local handle, opts = drive(nil, "outpost-sync-gate-failed: no outpost\n", 1)

        sync.sync(endpoint, opts, function() end)

        assert.are_same({ "phase: probing the outpost", "gate" }, kinds(handle))
    end)

    it("forwards raw rsync output to the injected handle", function()
        local handle, opts = drive()

        sync.sync(endpoint, opts, function() end)

        local rsync_event = handle.events[5]

        assert.equal("rsync", rsync_event.kind)

        rsync_event.on_chunk("        2,048   1%    9.54MB/s    0:00:00", "stdout")
        rsync_event.on_chunk("rsync: boom\n", "stderr")

        local streamed = {}

        for _, event in ipairs(handle.events) do
            if event.kind == "stream" then
                table.insert(streamed, event.chunk .. "|" .. event.source)
            end
        end

        assert.are_same({ "        2,048   1%    9.54MB/s    0:00:00|stdout", "rsync: boom\n|stderr" }, streamed)
    end)

    it("opens no window of its own when the engine runs without an injected view", function()
        local wins_before = #vim.api.nvim_list_wins()

        local _, opts = drive()

        opts.view = nil

        sync.sync(endpoint, opts, function() end)

        assert.equal(wins_before, #vim.api.nvim_list_wins())
    end)
end)

describe("sync rsync stream seam", function()
    it("streams every chunk and rebuilds the output for the stats parser", function()
        local chunks, result = {}, nil

        sync.default_rsync(
            {
                "printf",
                "%s",
                "\r        2,048   1%\nNumber of regular files transferred: 3\nTotal transferred file size: 1,654 bytes\n",
            },
            nil,
            function(res)
                result = res
            end,
            function(chunk, source)
                table.insert(chunks, { chunk = chunk, source = source })
            end
        )

        assert.truthy(
            vim.wait(5000, function()
                return result ~= nil
            end),
            "the transfer never finished"
        )

        local streamed = {}

        for _, pipe in ipairs(chunks or {}) do
            assert.equal("stdout", pipe.source)
            table.insert(streamed, pipe.chunk)
        end

        local output =
            "\r        2,048   1%\nNumber of regular files transferred: 3\nTotal transferred file size: 1,654 bytes\n"

        assert.equal(output, table.concat(streamed))
        assert.equal(output, result.stdout)
        assert.are_same({ files = 3, bytes = 1654 }, sync.parse_stats(result.stdout))
        assert.equal(0, result.code)
    end)

    it("streams both pipes without confusing them", function()
        local chunks, result = {}, nil

        sync.default_rsync({ "sh", "-c", "printf 'out\\n'; printf 'err\\n' >&2" }, nil, function(res)
            result = res
        end, function(chunk, source)
            table.insert(chunks, { chunk = chunk, source = source })
        end)

        assert.truthy(vim.wait(5000, function()
            return result ~= nil
        end))

        local by_source = { stdout = {}, stderr = {} }

        for _, pipe in ipairs(chunks or {}) do
            table.insert(by_source[pipe.source], pipe.chunk)
        end

        assert.equal("out\n", table.concat(by_source.stdout))
        assert.equal("err\n", table.concat(by_source.stderr))
        assert.equal("out\n", result.stdout)
        assert.equal("err\n", result.stderr)
    end)

    it("accumulates as before when no handler is given", function()
        local result

        sync.default_rsync({ "printf", "abc\\n" }, nil, function(res)
            result = res
        end)

        assert.truthy(vim.wait(5000, function()
            return result ~= nil
        end))

        assert.equal("abc\n", result.stdout)
        assert.equal(0, result.code)
    end)
end)

describe("sync command surface", function()
    local stub = require "luassert.stub"

    local real_notify
    local notifications
    local report

    before_each(function()
        real_notify = vim.notify
        notifications = {}

        vim.notify = function(msg, level)
            table.insert(notifications, { msg = msg, level = level })
        end

        report = stub(present, "report")
    end)

    after_each(function()
        vim.notify = real_notify
        report:revert()
    end)

    -- The engine fires its callback only when the spec tells it to; the
    -- live count defaults to zero. `extra` carries the view seams.
    local function run_with(live, extra)
        local release

        sync.run(
            "box",
            vim.tbl_extend("force", {
                endpoint = "outpost@box",
                live_count = function(_, _, callback)
                    callback(live or 0)
                end,
                engine = function(_, _, callback)
                    release = callback
                end,
            }, extra or {})
        )

        return release
    end

    local function saw(view, kind)
        for _, event in ipairs(view.events) do
            if event.kind == kind then
                return true
            end
        end

        return false
    end

    it("notifies 'syncing' while the engine is still running", function()
        run_with()

        assert.equal(1, #notifications)
        assert.truthy(notifications[1].msg:find("syncing box", 1, true))
    end)

    it("announces the aggregate stats on success", function()
        local release = run_with()

        release({ stats = { files = 12, bytes = 2048 } }, nil)

        assert.equal(2, #notifications)
        assert.truthy(notifications[2].msg:find("synced box", 1, true))
        assert.truthy(notifications[2].msg:find("12 files", 1, true))
        assert.truthy(notifications[2].msg:find("2.0 KiB", 1, true))
    end)

    it("skips the stats parenthetical when no stats could be parsed", function()
        local release = run_with()

        release({ stats = nil }, nil)

        assert.equal(2, #notifications)
        assert.falsy(notifications[2].msg:find "%(")
    end)

    it("mentions degraded treesitter in the success notification", function()
        local release = run_with()

        release({ stats = { files = 0, bytes = 0 } }, nil)

        assert.truthy(notifications[2].msg:find("treesitter", 1, true))
    end)

    it("fires the honest live-session warning after a successful sync", function()
        local release = run_with(2)

        release({ stats = { files = 0, bytes = 0 } }, nil)

        assert.equal(3, #notifications)
        assert.equal(vim.log.levels.WARN, notifications[3].level)
        assert.truthy(notifications[3].msg:find("2 live session(s) are running", 1, true))
        assert.truthy(notifications[3].msg:find("may misbehave until restarted", 1, true))
    end)

    it("stays silent when no session is live", function()
        local release = run_with(0)

        release({ stats = { files = 0, bytes = 0 } }, nil)

        assert.equal(2, #notifications)
    end)

    it("does not warn when the sync fails", function()
        local release = run_with(3)

        release(nil, "rsync failed", nil)

        assert.equal(2, #notifications)
    end)

    it("keeps the view open and focused on failure, and errors - the failure float is gone", function()
        local view = recording_view()
        local release = run_with(nil, {
            progress = function()
                return view
            end,
        })

        release(nil, "rsync failed", "boom line one\nboom line two")

        assert.equal(2, #notifications)
        assert.equal(vim.log.levels.ERROR, notifications[2].level)
        assert.truthy(saw(view, "fail"))
        assert.equal(0, #report.calls, "the centered failure float is superseded")
    end)

    it("errors without output, still ending the view", function()
        local view = recording_view()
        local release = run_with(nil, {
            progress = function()
                return view
            end,
        })

        release(nil, "the outpost at outpost@box predates the rsync bundle", nil)

        assert.equal(0, #report.calls)
        assert.equal(vim.log.levels.ERROR, notifications[2].level)
        assert.truthy(saw(view, "fail"))
    end)

    it("auto-closes the view on success, notifications unchanged", function()
        local view = recording_view()
        local release = run_with(nil, {
            progress = function()
                return view
            end,
        })

        release({ stats = { files = 12, bytes = 2048 } }, nil)

        assert.truthy(saw(view, "succeed"))
        assert.falsy(saw(view, "fail"))
        assert.truthy(notifications[2].msg:find("synced box", 1, true))
    end)

    it("backs one invocation with exactly one handle from the injected factory", function()
        local views = {}

        sync.run("box", {
            endpoint = "outpost@box",
            progress = function()
                local view = recording_view()

                table.insert(views, view)
                return view
            end,
            live_count = function(_, _, callback)
                callback(0)
            end,
            engine = function(_, _, callback)
                callback({ stats = { files = 0, bytes = 0 } }, nil)
            end,
        })

        assert.equal(1, #views)
        assert.truthy(saw(views[1], "succeed"))
    end)

    it("hands the created view to the engine for its phases and streams", function()
        local view = recording_view()
        local seen

        sync.run("box", {
            endpoint = "outpost@box",
            progress = function()
                return view
            end,
            engine = function(_, engine_opts, callback)
                seen = engine_opts.view
                callback({ stats = { files = 0, bytes = 0 } }, nil)
            end,
        })

        assert.equal(view, seen)
    end)

    it("resolves the endpoint from the registry before any expansion", function()
        local dir = vim.fn.tempname()

        vim.fn.mkdir(dir, "p")
        registry.record(dir, {
            session_id = "00ac56",
            endpoint = "outpost@10.0.0.4",
            canonical_path = "/srv/proj",
            typed_target = "outpost@box:~/proj",
        })

        local seen

        sync.run("box", {
            registry_dir = dir,
            live_count = function(_, _, callback)
                callback(0)
            end,
            engine = function(endpoint, _, callback)
                seen = endpoint
                callback({ stats = { files = 0, bytes = 0 } }, nil)
            end,
        })

        assert.equal("outpost@10.0.0.4", seen)

        vim.fn.delete(dir, "rf")
    end)

    it("falls back to the injected resolver for unregistered hosts", function()
        local seen

        sync.run("freshbox", {
            resolve_host = function(host, _, callback)
                callback("outpost@" .. host, nil)
            end,
            live_count = function(_, _, callback)
                callback(0)
            end,
            engine = function(endpoint, _, callback)
                seen = endpoint
                callback({ stats = { files = 0, bytes = 0 } }, nil)
            end,
        })

        assert.equal("outpost@freshbox", seen)
    end)

    it("fails on a resolver error, naming the host", function()
        sync.run("ghost", {
            resolve_host = function(_, _, callback)
                callback(nil, "ssh -G failed for ghost")
            end,
        })

        assert.equal(1, #notifications)
        assert.truthy(notifications[1].msg:find("ghost", 1, true))
        assert.equal(vim.log.levels.ERROR, notifications[1].level)
    end)

    it("reports the missing local rsync from the engine", function()
        sync.run("box", {
            endpoint = "outpost@box",
            executable = function()
                return 0
            end,
        })

        assert.equal(2, #notifications)
        assert.truthy(notifications[1].msg:find("syncing box", 1, true))
        assert.truthy(notifications[2].msg:find("no local rsync", 1, true))
        assert.equal(vim.log.levels.ERROR, notifications[2].level)
    end)
end)

describe("sync command surface opt-out", function()
    local stub = require "luassert.stub"

    local endpoint = "outpost@box"
    local conn = { port = "2222" }
    local STATS = "Number of regular files transferred: 3\nTotal transferred file size: 1,654 bytes\n"

    local real_notify
    local notifications

    before_each(function()
        real_notify = vim.notify

        notifications = {}

        vim.notify = function(msg, level)
            table.insert(notifications, { msg = msg, level = level })
        end
    end)

    after_each(function()
        vim.notify = real_notify
        config.setup {}
    end)

    -- The view's window: whatever appeared beyond the drive's baseline.
    local function new_window(wins_before)
        local wins = vim.api.nvim_list_wins()

        if #wins <= wins_before then
            return nil
        end

        for _, win in ipairs(wins) do
            if vim.api.nvim_win_get_config(win).split == "below" then
                return win
            end
        end

        return wins[#wins]
    end

    -- Drives the real engine behind sync.run with stubbed round trips; the
    -- window machinery is pretended so a real handle would open a window.
    -- The mid-flight assert guards against the success auto-close hiding a
    -- window that did open.
    local function drive(rsync_result, expect_no_window)
        local ui = stub(vim.api, "nvim_list_uis").returns { { focusable = true } }
        local wins_before = #vim.api.nvim_list_wins()

        sync.run("box", {
            endpoint = endpoint,
            conn = conn,
            executable = function()
                return 1
            end,
            config_root = "/base/cfg",
            data_root = "/base/dat",
            transport = {
                run = function(_, command, _, callback)
                    if command:find("synced", 1, true) then
                        callback(0, "", nil)
                    else
                        callback(0, "/home/o\n", nil)
                    end
                end,
            },
            rsync = function(_, callback)
                if expect_no_window then
                    assert.equal(wins_before, #vim.api.nvim_list_wins(), "no window may open for a disabled view")
                end

                callback(rsync_result or { code = 0, stdout = STATS, stderr = "" })
            end,
        })

        if expect_no_window then
            assert.equal(wins_before, #vim.api.nvim_list_wins(), "no window may survive a disabled view")
        end

        return ui, wins_before
    end

    it("opens no window across the whole ladder when the view is disabled", function()
        config.setup { progress = false }

        local ui = drive(nil, true)

        assert.equal(2, #notifications)
        assert.equal(vim.log.levels.INFO, notifications[2].level)
        assert.truthy(notifications[2].msg:find("synced box", 1, true))

        ui:revert()
    end)

    it("surfaces the failing rsync's full output via the notification when the view is disabled", function()
        config.setup { progress = false }

        local ui = drive({ code = 23, stdout = "boom-out\n", stderr = "boom-err\n" }, true)

        assert.equal(vim.log.levels.ERROR, notifications[2].level)
        assert.truthy(notifications[2].msg:find("boom-out", 1, true), "the full output must reach the notification")
        assert.truthy(notifications[2].msg:find("boom-err", 1, true))

        ui:revert()
    end)

    it("keeps the failure one line in the notification and the output in the view when the view is enabled", function()
        local ui, wins_before = drive { code = 23, stdout = "boom-out\n", stderr = "boom-err\n" }

        assert.falsy(notifications[2].msg:find("boom-out", 1, true), "the view is the full-output surface")

        -- a failure keeps its window for the user to read
        local progress_win = new_window(wins_before)

        assert.truthy(progress_win and vim.api.nvim_win_is_valid(progress_win))

        vim.api.nvim_win_close(progress_win, true)
        ui:revert()
    end)
end)

describe("sync askpass bridge", function()
    local auth = require "outpost.auth"

    local stub = require "luassert.stub"

    local endpoint = "outpost@box"
    local conn = { mux = false, askpass = true }

    after_each(function()
        config.setup {}
    end)

    it("omits BatchMode from the ssh command when the bridge is installed", function()
        config.setup { askpass = true }

        local argv = sync.build_rsync_argv("/base/cfg/", endpoint .. ":/d", "/home/o", conn)
        local e

        for index, value in ipairs(argv) do
            if value == "-e" then
                e = argv[index + 1]
            end
        end

        assert.truthy(e, "-e must be present")
        assert.falsy(e:find("BatchMode=yes", 1, true))
    end)

    it("attaches the bridge env to each rsync invocation", function()
        local env = { OUTPOST_ASKPASS_TOKEN = "tok" }
        local env_stub = stub(auth, "env").returns(env, function() end)
        local rsync_stub = stub(sync, "default_rsync").invokes(function(_, _, callback)
            callback {
                code = 0,
                stdout = "Number of regular files transferred: 1\nTotal transferred file size: 1 bytes",
                stderr = "",
            }
        end)

        local opts = {
            conn = conn,
            executable = function()
                return 1
            end,
            config_root = "/base/cfg",
            data_root = "/base/dat",
            transport = {
                run = function(_, command, _, callback)
                    if command:find("synced", 1, true) then
                        callback(0, "", nil)
                    else
                        callback(0, "/home/o\n", nil)
                    end
                end,
            },
        }

        sync.sync(endpoint, opts, function() end)

        assert.stub(sync.default_rsync).was_called(2)
        assert.are.same(env, rsync_stub.calls[1].refs[2])
        assert.are.same(env, rsync_stub.calls[2].refs[2])

        env_stub:revert()
        rsync_stub:revert()
    end)

    it("streams the bridge's failure reason into the view", function()
        local handle = recording_view()

        local env_stub = stub(auth, "env").returns({}, function()
            return "credential prompt cancelled"
        end)

        local rsync_stub = stub(sync, "default_rsync").invokes(function(_, _, callback)
            callback { code = 255, stdout = "", stderr = "" }
        end)

        sync.sync(endpoint, {
            conn = conn,
            view = handle,
            executable = function()
                return 1
            end,
            config_root = "/base/cfg",
            data_root = "/base/dat",
            transport = {
                run = function(_, _, _, callback)
                    callback(0, "/home/o\n", nil)
                end,
            },
        }, function() end)

        local streamed = {}

        for _, event in ipairs(handle.events) do
            if event.kind == "stream" then
                table.insert(streamed, event.chunk .. "|" .. event.source)
            end
        end

        assert.are_same({ "credential prompt cancelled\n|stderr" }, streamed)

        env_stub:revert()
        rsync_stub:revert()
    end)
end)
