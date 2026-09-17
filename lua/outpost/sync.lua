-- `sync`: push the base's config and data trees into an outpost, one-way,
-- local-is-truth, riding the outpost's bundled rsync.

local auth = require "outpost.auth"
local config = require "outpost.config"
local progress = require "outpost.progress"
local registry = require "outpost.registry"
local scan = require "outpost.scan"
local session = require "outpost.session"
local transport = require "outpost.transport"
local up = require "outpost.up"

local M = {}

-- One ssh round trip: refuse a missing outpost, probe the bundled rsync's
-- executability, pre-create the config/data roots privately, print the
-- account's absolute home (used verbatim in --rsync-path, never tilde).
function M.build_gate_command()
    return [[
set -eu
OUTPOST="$HOME/.cache/outpost"
if [ ! -d "$OUTPOST" ]; then
    echo 'outpost-sync-gate-failed: no outpost'
    exit 1
fi
RSYNC="$OUTPOST/install/current/bin/rsync"
if [ ! -x "$RSYNC" ]; then
    echo 'outpost-sync-gate-failed: no bundled rsync'
    exit 1
fi
mkdir -p -m 700 "$OUTPOST/config" "$OUTPOST/data"
chmod 700 "$OUTPOST/config" "$OUTPOST/data"
printf '%s\n' "$HOME"
]]
end

-- The gate probe's single output line: the outpost's absolute home.
function M.parse_gate_output(output)
    local home = vim.trim(output or "")

    -- --rsync-path is executed by the remote shell: a relative or tilde
    -- home would be garbage there
    if not home:match "^/" then
        return nil
    end

    return (home:match "^[^\n]+")
end

-- The mandatory exclusion floor relative to the root being synced: the
-- local registry directory, mason, and all native artifacts. Hide rules -
-- excluded from transfer and deletable remotely, never shielded from
-- --delete. User patterns append as hide rules, so they can never replace
-- or unhide the floor.
function M.exclude_filters(user_excludes)
    local filters = { "-f", "H outpost/", "-f", "H mason/", "-f", "H *.so" }

    for _, pattern in ipairs(user_excludes or {}) do
        if type(pattern) == "string" and pattern ~= "" then
            vim.list_extend(filters, { "-f", "H " .. pattern })
        end
    end

    return filters
end

-- Where one tree lands on the outpost: its relocated XDG home with the
-- forced NVIM_APPNAME=nvim as the leaf.
function M.remote_dest(endpoint, home, tree)
    return ("%s:%s/.cache/outpost/%s/nvim/"):format(endpoint, home, tree)
end

-- One rsync invocation. `home` is the absolute home from the gate probe -
-- tilde expansion is never used.
function M.build_rsync_argv(source_root, dest, home, conn, user_excludes)
    local argv = { "rsync", "-a", "--no-owner", "--no-group", "--no-D", "--delete", "--stats", "--info=progress2" }

    vim.list_extend(argv, M.exclude_filters(user_excludes))

    local ssh_args = {}

    for _, arg in ipairs(transport.ssh_args(conn)) do
        table.insert(ssh_args, transport.shell_quote(arg))
    end

    table.insert(argv, "-e")
    table.insert(argv, "ssh " .. table.concat(ssh_args, " "))
    table.insert(argv, "--rsync-path=" .. transport.shell_quote(home .. "/.cache/outpost/install/current/bin/rsync"))
    table.insert(argv, source_root)
    table.insert(argv, dest)

    return argv
end

-- The outpost-owned record that a full sync succeeded. Written only after
-- both invocations exit 0.
function M.build_marker_command()
    return [[
set -eu
mkdir -p "$HOME/.cache/outpost"
printf '%s\n' "$(date +%s)" > "$HOME/.cache/outpost/synced"
chmod 600 "$HOME/.cache/outpost/synced"
]]
end

-- The marker probe: reports whether a successful sync has ever been
-- recorded on the outpost.
function M.build_marker_probe_command()
    return [[
if [ -e "$HOME/.cache/outpost/synced" ]; then
    printf 'synced\n'
else
    printf 'unsynced\n'
fi
]]
end

-- Whether the outpost's sync marker stands. callback(synced, err).
function M.has_marker(endpoint, opts, callback)
    opts = opts or {}

    local transport_mod = opts.transport or transport

    transport_mod.run(endpoint, M.build_marker_probe_command(), opts.conn, function(code, out, err)
        if code ~= 0 then
            callback(nil, err or ("sync marker probe failed (exit " .. tostring(code) .. ")"))
            return
        end

        callback(vim.trim(out or "") == "synced", nil)
    end)
end

-- The transfer numbers from one --stats run, or nil when unreadable.
function M.parse_stats(output)
    local files = (output or ""):match "Number of regular files transferred: (%d+)"
    local bytes = (output or ""):match "Total transferred file size: ([%d,]+) bytes"

    if not (files and bytes) then
        return nil
    end

    return { files = tonumber(files), bytes = tonumber((bytes:gsub(",", ""))) }
end

-- One aggregate over the two invocations' stats; nil when either run's
-- stats are unreadable.
function M.aggregate_stats(first, second)
    if not (first and second) then
        return nil
    end

    return { files = first.files + second.files, bytes = first.bytes + second.bytes }
end

-- The gate failure's user-facing explanation: which fix to run.
local function gate_error(endpoint, output, code)
    if output:find "no outpost" then
        return ("no outpost on %s - run :Outpost up <host> first"):format(endpoint)
    end

    if output:find "no bundled rsync" then
        return ("the outpost at %s predates the rsync bundle - run :Outpost update <host> first"):format(endpoint)
    end

    return ("sync gate failed on %s (exit %d)"):format(endpoint, code)
end

-- One async rsync invocation; the optional output handler rides the shared
-- streaming runner, so the result is rebuilt from the same chunks. The bridge
-- env rides along so rsync's ssh child can ask the base.
function M.default_rsync(argv, env, callback, on_chunk)
    transport.streamed(argv, { text = true, env = env }, callback, on_chunk)
end

-- The sync engine: gate, then config rsync, then data rsync, then the
-- marker. callback(result, err, detail) - result = { stats = aggregate };
-- detail carries the failing invocation's output for presentation.
function M.sync(endpoint, opts, callback)
    opts = opts or {}

    local transport_mod = opts.transport or transport
    local run_remote = transport_mod.run
    local executable = opts.executable or vim.fn.executable
    local user_excludes = opts.exclude or config.sync_exclude()
    local view = opts.view or progress.null()

    local function stream(chunk, source)
        view:stream(chunk, source)
    end

    -- Each rsync gets its own bridge so a credential can be asked for the
    -- ssh child it spawns.
    local function bridged_rsync(argv, rsync_callback, on_chunk)
        local env, close = auth.env(endpoint, opts.conn)

        M.default_rsync(argv, env, function(result)
            local reason = close and close()

            if reason and (result.code or 0) ~= 0 then
                result.stderr = reason
                stream(reason .. "\n", "stderr")
            end

            rsync_callback(result)
        end, on_chunk)
    end

    local run_rsync = opts.rsync or bridged_rsync

    if executable "rsync" ~= 1 then
        callback(nil, "no local rsync on the base - sync needs rsync")
        return
    end

    -- ssh does not create its mux socket directory itself, and rsync's -e
    -- hands it the same ControlPath as every other command
    if transport_mod.ensure_mux_dir then
        transport_mod.ensure_mux_dir(opts.conn)
    end

    local trees = {
        { tree = "config", root = opts.config_root },
        { tree = "data", root = opts.data_root },
    }
    local stats = {}
    local home

    local function run_tree(index)
        local entry = trees[index]

        if not entry then
            view:phase "writing the sync marker"

            run_remote(endpoint, M.build_marker_command(), opts.conn, function(code, _, err)
                if code ~= 0 then
                    callback(nil, "sync marker write failed: " .. (err or ("exit " .. code)))
                    return
                end

                callback({ stats = M.aggregate_stats(stats[1], stats[2]) }, nil)
            end)
            return
        end

        -- The transfer is the operation's first not-guaranteed-short phase:
        -- the gate probe and the marker write never materialize the window.
        if index == 1 then
            view:open()
        end

        view:phase(("syncing the %s tree"):format(entry.tree))

        local source = (entry.root or vim.fn.stdpath(entry.tree)) .. "/"
        local argv =
            M.build_rsync_argv(source, M.remote_dest(endpoint, home, entry.tree), home, opts.conn, user_excludes)

        run_rsync(argv, function(result)
            if (result.code or 0) ~= 0 then
                callback(
                    nil,
                    ("rsync failed for the %s tree (exit %s)"):format(entry.tree, tostring(result.code)),
                    vim.trim((result.stdout or "") .. "\n" .. (result.stderr or ""))
                )
                return
            end

            stats[index] = M.parse_stats(result.stdout)
            run_tree(index + 1)
        end, stream)
    end

    view:phase "probing the outpost"

    run_remote(endpoint, M.build_gate_command(), opts.conn, function(code, out, err)
        if code ~= 0 then
            callback(nil, gate_error(endpoint, out or err or "", code))
            return
        end

        home = M.parse_gate_output(out)

        if not home then
            callback(nil, "unreadable gate output for " .. endpoint)
            return
        end

        run_tree(1)
    end)
end

-- How many of the outpost's sessions are live right now. Advisory: an
-- unreachable scan or probe counts as zero rather than failing the sync.
function M.live_count(endpoint, opts, callback)
    opts = opts or {}

    local scanner = opts.scan or scan.host
    local prober = opts.probe or session.probe

    scanner(endpoint, opts.conn, function(entries)
        entries = entries or {}

        if #entries == 0 then
            callback(0)
            return
        end

        local live = 0
        local pending = #entries

        for _, entry in ipairs(entries) do
            prober(endpoint, entry.session_id, opts.conn, function(state)
                if state and state.state == "live" then
                    live = live + 1
                end

                pending = pending - 1

                if pending == 0 then
                    callback(live)
                end
            end)
        end
    end)
end

-- A host's endpoint: the shared registry resolution - a registered entry
-- when one was recorded (it was already resolved through the identity
-- ladder), otherwise the ssh-config expansion, which refuses a
-- base-resolving host.
local function resolve_endpoint(host, opts, callback)
    local entries = registry.all(registry.dir(opts.registry_dir))

    registry.resolve_endpoint(host, opts, entries, opts.resolve_host or up.expand_host, callback)
end

-- The `sync` command surface: resolve the endpoint, announce, run the
-- engine, and present the outcome - the stats summary on success, the
-- progress view (kept open, focused) on failure.
function M.run(host, opts)
    opts = opts or {}

    local function fail(err, detail)
        -- with the view opted out the notification is the only failure surface
        if detail and detail ~= "" and not config.progress() then
            vim.notify(("outpost: %s\n%s"):format(err, detail), vim.log.levels.ERROR)
            return
        end

        vim.notify("outpost: " .. err, vim.log.levels.ERROR)
    end

    resolve_endpoint(host, opts, function(endpoint, resolve_err)
        if not endpoint then
            fail(resolve_err)
            return
        end

        -- One handle per invocation; the engine's phases and the rsync
        -- stream render into it, and the operation owns its lifecycle.
        local view = opts.view or (opts.progress or progress.create)()

        vim.notify(("outpost: syncing %s…"):format(host), vim.log.levels.INFO)

        local engine = opts.engine or M.sync

        engine(endpoint, vim.tbl_extend("force", opts, { view = view }), function(result, err, detail)
            if not result then
                view:fail()
                fail(err, detail)
                return
            end

            view:succeed()

            local summary = ""

            if result.stats then
                summary = (" (%d files, %s)"):format(result.stats.files, progress.format_size(result.stats.bytes))
            end

            vim.notify(
                ("outpost: synced %s%s\ntreesitter is degraded on outposts: native parsers are not synced"):format(
                    host,
                    summary
                ),
                vim.log.levels.INFO
            )

            local count_live = opts.live_count or M.live_count

            count_live(endpoint, opts, function(count)
                if count and count > 0 then
                    vim.notify(
                        (
                            "outpost: %d live session(s) are running from files sync just changed; "
                            .. "they may misbehave until restarted (stop + up)"
                        ):format(count),
                        vim.log.levels.WARN
                    )
                end
            end)
        end)
    end)
end

return M
