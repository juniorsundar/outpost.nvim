-- Candidate generation for `:Outpost <Tab>` completion: subcommands first,
-- then per-subcommand targets or known hosts.

local registry = require "outpost.registry"
local sshconfig = require "outpost.sshconfig"

local M = {}

local SUBCOMMANDS = { "up", "update", "list", "stop", "down" }

function M.subcommands()
    return vim.deepcopy(SUBCOMMANDS)
end

local function default_registry_dir()
    return vim.fs.joinpath(vim.fn.stdpath "data", "outpost")
end

-- Registry entries sorted most-recently-used first.
local function entries(opts)
    local all = registry.all(opts.registry_dir or default_registry_dir())
    local list = {}

    for session_id, entry in pairs(all) do
        entry.session_id = session_id
        table.insert(list, entry)
    end

    table.sort(list, function(a, b)
        local left, right = a["last-used"] or 0, b["last-used"] or 0

        if left ~= right then
            return left > right
        end

        return a.session_id < b.session_id
    end)

    return list
end

local function target(entry)
    if entry.typed_target and entry.typed_target ~= "" then
        return entry.typed_target
    end

    return entry.endpoint .. ":" .. entry.canonical_path
end

local function host_of(entry)
    local host = entry.typed_target and entry.typed_target:match "^[^@]+@([^:]+):"

    if host then
        return host
    end

    return entry.endpoint and entry.endpoint:match "@(.+)$"
end

local function filter(candidates, arglead)
    if not arglead or arglead == "" then
        return candidates
    end

    return vim.tbl_filter(function(candidate)
        return vim.startswith(candidate, arglead)
    end, candidates)
end

-- Both target forms: ssh-config hosts, then each known session's id and its
-- recorded (or reconstructed) `user@host:path`.
function M.up(arglead, opts)
    opts = opts or {}

    local candidates = {}

    vim.list_extend(candidates, sshconfig.read(opts.ssh_config))

    for _, entry in ipairs(entries(opts)) do
        table.insert(candidates, entry.session_id)
        table.insert(candidates, target(entry))
    end

    return filter(candidates, arglead)
end

-- Every registered session id, with no state filter: classifying
-- live/dead/unreachable needs a probe, which completion (synchronous) can
-- never run. stop's own resolution enforces state.
function M.stop(arglead, opts)
    opts = opts or {}

    local candidates = {}

    for _, entry in ipairs(entries(opts)) do
        table.insert(candidates, entry.session_id)
    end

    return filter(candidates, arglead)
end

-- Known hosts: ssh-config aliases plus the hosts of recorded sessions.
function M.hosts(arglead, opts)
    opts = opts or {}

    local candidates = {}
    local seen = {}

    local function add(value)
        if value and value ~= "" and not seen[value] then
            seen[value] = true
            table.insert(candidates, value)
        end
    end

    for _, host in ipairs(sshconfig.read(opts.ssh_config)) do
        add(host)
    end

    for _, entry in ipairs(entries(opts)) do
        add(host_of(entry))
    end

    return filter(candidates, arglead)
end

return M
