-- `:Outpost list`: a read-only report of every session across every known
-- host. The remote run/ scan is ground truth; the local registry supplies
-- the typed target a session was reached by, when one was recorded.

local config = require "outpost.config"
local present = require "outpost.present"
local registry = require "outpost.registry"
local scan = require "outpost.scan"
local session = require "outpost.session"
local sshconfig = require "outpost.sshconfig"
local up = require "outpost.up"

local M = {}

-- Merge one host's registry entries with its scan results, keyed by
-- session id. A session known to both keeps the registry's typed_target; a
-- session the scan found that the registry never recorded is adopted; a
-- registry entry the scan could not reach (host unreachable) is kept as-is.
function M.merge(registry_entries, scanned)
    local merged = {}
    local seen = {}

    for session_id, entry in pairs(registry_entries or {}) do
        entry = vim.tbl_extend("force", { session_id = session_id }, entry)
        merged[session_id] = entry
        seen[session_id] = true
    end

    for _, entry in ipairs(scanned or {}) do
        if seen[entry.session_id] then
            merged[entry.session_id] = vim.tbl_extend("force", entry, {
                typed_target = merged[entry.session_id].typed_target,
            })
        else
            merged[entry.session_id] = entry
        end
    end

    local list = {}

    for _, entry in pairs(merged) do
        table.insert(list, entry)
    end

    table.sort(list, function(a, b)
        return a.session_id < b.session_id
    end)

    return list
end

-- Split classified entries into what a report keeps and what it drops.
-- Dead entries are always dropped (registry-local GC); unreachable entries
-- are dropped only when banged (the purge, ADR-0011). callback returns
-- (kept, removed_session_ids).
function M.gc_and_purge(entries, bang)
    local kept = {}
    local removed = {}

    for _, entry in ipairs(entries) do
        if entry.state == "dead" then
            table.insert(removed, entry.session_id)
        elseif entry.state == "unreachable" and bang then
            table.insert(removed, entry.session_id)
        else
            table.insert(kept, entry)
        end
    end

    return kept, removed
end

local function target_of(entry)
    if entry.typed_target and entry.typed_target ~= "" then
        return entry.typed_target
    end

    return (entry.endpoint or "?") .. ":" .. (entry.canonical_path or "?")
end

-- Render the report's lines: one per entry, or a plain "nothing found" line.
function M.render(entries)
    if #entries == 0 then
        return { "outpost: no sessions found" }
    end

    local lines = {}

    for _, entry in ipairs(entries) do
        table.insert(lines, ("%s  %s (%s)"):format(entry.session_id, target_of(entry), entry.state))
    end

    return lines
end

local function default_registry_dir()
    return vim.fs.joinpath(vim.fn.stdpath "data", "outpost")
end

-- Group the registry by the host each entry was typed against.
local function registry_by_host(all)
    local by_host = {}

    for session_id, entry in pairs(all) do
        entry = vim.tbl_extend("force", { session_id = session_id }, entry)

        local host = registry.host_of(entry)

        if host then
            by_host[host] = by_host[host] or {}
            by_host[host][session_id] = entry
        end
    end

    return by_host
end

-- Resolve the endpoint to scan a host with: a registered session's endpoint
-- when one is known, otherwise expand the bare ssh-config host (same ladder
-- `up`'s picker uses for a host with no prior session).
local function resolve_scan_endpoint(host, host_registry, opts, callback)
    for _, entry in pairs(host_registry) do
        callback(entry.endpoint, nil)
        return
    end

    local resolver = opts.resolve_host or up.expand_host

    resolver(host, opts, callback)
end

-- Scan every known host (registry ∪ ssh-config), or just `host` when given,
-- probe every found session's liveness, merge with the registry, and
-- callback(entries).
local function collect(opts, host_filter, callback)
    local dir = opts.registry_dir or default_registry_dir()
    local all = registry.all(dir)
    local by_host = registry_by_host(all)

    for _, host in ipairs(sshconfig.read(opts.ssh_config)) do
        by_host[host] = by_host[host] or {}
    end

    local hosts = vim.tbl_keys(by_host)

    table.sort(hosts)

    if host_filter and host_filter ~= "" then
        hosts = vim.tbl_filter(function(host)
            return host == host_filter
        end, hosts)
    end

    if #hosts == 0 then
        callback {}
        return
    end

    local scanned_entries = {}
    local pending = #hosts

    -- Two host names (an ssh-config alias and a literal host the user
    -- typed) can resolve to the same physical endpoint: each scans it
    -- independently, so the same session id can surface twice. Dedup by
    -- session id before probing - a plain table key, since a session id is
    -- globally unique by construction.
    local function dedup(list)
        local by_id = {}
        local ordered = {}

        for _, entry in ipairs(list) do
            if not by_id[entry.session_id] then
                by_id[entry.session_id] = entry
                table.insert(ordered, entry)
            end
        end

        return ordered
    end

    local function probe_and_finish()
        local entries = dedup(scanned_entries)
        local probe_pending = #entries

        if probe_pending == 0 then
            callback(entries)
            return
        end

        for _, entry in ipairs(entries) do
            session.probe(
                entry.endpoint,
                entry.session_id,
                config.conn(registry.host_of(entry), opts.conn),
                function(state)
                    entry.state = state and state.state or "unreachable"
                    probe_pending = probe_pending - 1

                    if probe_pending == 0 then
                        callback(entries)
                    end
                end
            )
        end
    end

    local function host_done()
        pending = pending - 1

        if pending == 0 then
            probe_and_finish()
        end
    end

    for _, host in ipairs(hosts) do
        resolve_scan_endpoint(host, by_host[host], opts, function(endpoint, resolve_err)
            if not endpoint then
                host_done()
                return
            end

            scan.host(endpoint, config.conn(host, opts.conn), function(scanned)
                vim.list_extend(scanned_entries, M.merge(by_host[host], scanned))
                host_done()
            end)
        end)
    end
end

-- The full `list` flow: scan, merge, probe, GC/purge, report.
function M.run(host, opts)
    opts = opts or {}

    collect(opts, host, function(entries)
        local kept, removed = M.gc_and_purge(entries, opts.bang)
        local dir = opts.registry_dir or default_registry_dir()

        for _, session_id in ipairs(removed) do
            registry.remove(dir, session_id)
        end

        present.report(M.render(kept))
    end)
end

return M
