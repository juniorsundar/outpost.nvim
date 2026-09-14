-- ssh-config host enumeration: the aliases a picker or completion can offer
-- before any target exists.

local M = {}

-- The local ssh config the plugin reads by default.
function M.path()
    local home = vim.uv.os_homedir() or vim.env.HOME or "~"

    return vim.fs.joinpath(home, ".ssh", "config")
end

-- Literal Host aliases declared in ssh-config text, in file order, deduped.
-- Wildcard patterns and negations cannot be picked as a host, so they are
-- skipped.
function M.hosts(text)
    local aliases = {}
    local seen = {}

    for line in (text or ""):gmatch "[^\n]+" do
        local tokens = vim.split(vim.trim((line:gsub("#.*$", ""))), "%s+", { trimempty = true })

        if (tokens[1] or ""):lower() == "host" then
            for index = 2, #tokens do
                local alias = tokens[index]

                if alias ~= "" and not alias:find "[*?!]" and not seen[alias] then
                    seen[alias] = true
                    table.insert(aliases, alias)
                end
            end
        end
    end

    return aliases
end

-- Aliases from a config file; a missing file is simply no hosts.
function M.read(path)
    path = path or M.path()

    if vim.fn.filereadable(path) ~= 1 then
        return {}
    end

    return M.hosts(table.concat(vim.fn.readfile(path), "\n"))
end

return M
