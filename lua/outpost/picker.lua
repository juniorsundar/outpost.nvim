-- The bare-`up` picker: choose a live session, a registry entry, or an
-- ssh-config host, then run the full `up` flow for the chosen target.

local config = require "outpost.config"
local registry = require "outpost.registry"
local session = require "outpost.session"
local sshconfig = require "outpost.sshconfig"
local up = require "outpost.up"

local M = {}

local function session_target(entry)
    if entry.typed_target and entry.typed_target ~= "" then
        return entry.typed_target
    end

    return entry.endpoint .. ":" .. entry.canonical_path
end

-- Assemble picker entries from probed registry sessions and ssh-config
-- hosts. Sessions come first, most recently used first; hosts follow
-- alphabetically.
function M.entries(sessions, hosts)
    local entries = {}
    local ordered = vim.deepcopy(sessions or {})

    table.sort(ordered, function(a, b)
        local left, right = a["last-used"] or 0, b["last-used"] or 0

        if left ~= right then
            return left > right
        end

        return a.session_id < b.session_id
    end)

    for _, session in ipairs(ordered) do
        local target = session_target(session)

        table.insert(entries, {
            kind = "session",
            session_id = session.session_id,
            target = target,
            state = session.state,
            label = ("%s  %s (%s)"):format(session.session_id, target, session.state),
        })
    end

    local sorted_hosts = vim.deepcopy(hosts or {})

    table.sort(sorted_hosts)

    for _, host in ipairs(sorted_hosts) do
        table.insert(entries, {
            kind = "host",
            host = host,
            label = ("%s  (ssh-config host)"):format(host),
        })
    end

    return entries
end

-- Sessions in the live or dead state only, most-recently-used first: what
-- `stop`'s bare picker offers (unreachable sessions cannot be acted on).
function M.stop_entries(sessions)
    local actionable = vim.tbl_filter(function(entry)
        return entry.state == "live" or entry.state == "dead"
    end, sessions or {})

    return M.entries(actionable, {})
end

-- Every host with at least one registry entry, regardless of state: what
-- `down`'s bare picker offers. No ssh round trips - a host outside the
-- registry is still reachable by typing it directly.
function M.down_entries(sessions)
    local seen = {}
    local hosts = {}

    for _, entry in ipairs(sessions or {}) do
        local host = registry.host_of(entry)

        if host and not seen[host] then
            seen[host] = true
            table.insert(hosts, host)
        end
    end

    table.sort(hosts)

    local entries = {}

    for _, host in ipairs(hosts) do
        table.insert(entries, {
            kind = "host",
            host = host,
            label = ("%s  (known outpost)"):format(host),
        })
    end

    return entries
end

-- Resolve a host's effective user through the local ssh config (injectable
-- for offline specs, the same as up's endpoint expansion).
local function resolve_host(host, opts, callback)
    if opts.resolve_host then
        opts.resolve_host(host, callback)
        return
    end

    up.expand_host(host, opts, callback)
end

-- Present the entries and run the full `up` flow for the chosen one. A host
-- has no path up front, so its project path is prompted for; the alias is
-- preserved in the target so per-host config still applies.
function M.choose(entries, opts, run)
    opts = opts or {}

    if #entries == 0 then
        vim.notify("outpost: no sessions or hosts to choose from", vim.log.levels.INFO)
        return
    end

    vim.ui.select(entries, {
        prompt = "outpost target",
        format_item = function(entry)
            return entry.label
        end,
    }, function(choice)
        if not choice then
            return
        end

        if choice.kind == "session" then
            run(choice.target)
            return
        end

        vim.ui.input({ prompt = ("project path on %s: "):format(choice.host) }, function(path)
            if not path or vim.trim(path) == "" then
                return
            end

            resolve_host(choice.host, opts, function(endpoint_str, err)
                local user = endpoint_str and endpoint_str:match "^([^@]+)@"

                if not user then
                    vim.notify(
                        "outpost: could not resolve a user for " .. choice.host .. ": " .. (err or "no endpoint"),
                        vim.log.levels.ERROR
                    )
                    return
                end

                run(user .. "@" .. choice.host .. ":" .. vim.trim(path))
            end)
        end)
    end)
end

local function default_registry_dir()
    return vim.fs.joinpath(vim.fn.stdpath "data", "outpost")
end

-- Probe every registered session for liveness. callback(sessions) with each
-- entry's `state` set; a session that cannot be probed is still included,
-- flagged unreachable.
local function probe_registry(opts, callback)
    local dir = opts.registry_dir or default_registry_dir()
    local prober = opts.probe or session.probe
    local all = registry.all(dir)
    local sessions = {}
    local pending = vim.tbl_count(all)

    if pending == 0 then
        callback(sessions)
        return
    end

    for session_id, entry in pairs(all) do
        entry.session_id = session_id

        prober(entry.endpoint, session_id, config.conn(registry.host_of(entry), opts.conn), function(state)
            entry.state = state and state.state or "unreachable"
            table.insert(sessions, entry)
            pending = pending - 1

            if pending == 0 then
                callback(sessions)
            end
        end)
    end
end

-- Read the registry and ssh config, probe every recorded session for
-- liveness, and assemble the picker entries. A session that cannot be
-- probed is still offered, flagged unreachable.
function M.collect(opts, callback)
    opts = opts or {}

    probe_registry(opts, function(sessions)
        callback(M.entries(sessions, sshconfig.read(opts.ssh_config)))
    end)
end

-- The bare-`up` flow: collect the sources, let the user choose, and hand
-- the chosen target to `run` (which re-enters the full, typed-target `up`).
function M.pick(opts, run)
    M.collect(opts, function(entries)
        M.choose(entries, opts, run)
    end)
end

-- The bare-`stop` flow: probe registered sessions, offer only live/dead
-- ones, and hand the chosen session id to `run`.
function M.pick_stop(opts, run)
    opts = opts or {}

    probe_registry(opts, function(sessions)
        local entries = M.stop_entries(sessions)

        if #entries == 0 then
            vim.notify("outpost: no sessions to stop", vim.log.levels.INFO)
            return
        end

        vim.ui.select(entries, {
            prompt = "outpost session to stop",
            format_item = function(entry)
                return entry.label
            end,
        }, function(choice)
            if choice then
                run(choice.session_id)
            end
        end)
    end)
end

-- The bare-`down` flow: offer every host with a registry entry - no
-- probing, since down does not care about liveness - and hand the chosen
-- host to `run`.
function M.pick_down(opts, run)
    opts = opts or {}

    local dir = opts.registry_dir or default_registry_dir()
    local sessions = {}

    for session_id, entry in pairs(registry.all(dir)) do
        entry.session_id = session_id
        table.insert(sessions, entry)
    end

    local entries = M.down_entries(sessions)

    if #entries == 0 then
        vim.notify("outpost: no known outposts to tear down", vim.log.levels.INFO)
        return
    end

    vim.ui.select(entries, {
        prompt = "outpost to tear down",
        format_item = function(entry)
            return entry.label
        end,
    }, function(choice)
        if choice then
            run(choice.host)
        end
    end)
end

-- The bare-`sync` flow: the same host source as `down` (every host with a
-- registry entry, no probing), and hand the chosen host to `run`.
function M.pick_sync(opts, run)
    opts = opts or {}

    local dir = opts.registry_dir or default_registry_dir()
    local sessions = {}

    for session_id, entry in pairs(registry.all(dir)) do
        entry.session_id = session_id
        table.insert(sessions, entry)
    end

    local entries = M.down_entries(sessions)

    if #entries == 0 then
        vim.notify("outpost: no known outposts to sync", vim.log.levels.INFO)
        return
    end

    vim.ui.select(entries, {
        prompt = "outpost to sync",
        format_item = function(entry)
            return entry.label
        end,
    }, function(choice)
        if choice then
            run(choice.host)
        end
    end)
end

return M
