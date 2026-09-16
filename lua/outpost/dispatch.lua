-- Command dispatch: registers the single user command, routes subcommands
-- (`up`, `update`) to their handlers, and routes completion to them.

local M = {}

local function dispatch(handlers, fargs, bang)
    local subcommand = fargs[1]
    local argument = table.concat(fargs, " ", 2)

    local handler = handlers[subcommand]

    if not handler then
        error(("outpost: unknown subcommand: %s"):format(subcommand or ""))
    end

    handler.run(argument, bang)
end

-- The tokens typed so far and the 1-based argument position: 1 is the
-- command name, 2 the subcommand, 3+ the subcommand's own arguments.
local function position(cmdline, cursorpos)
    local before = cmdline:sub(1, cursorpos)
    local trailing_space = before:match "%s$" ~= nil
    local tokens = vim.split(vim.trim(before), "%s+", { trimempty = true })

    return tokens, #tokens + (trailing_space and 1 or 0)
end

local function complete(handlers, arglead, cmdline, cursorpos)
    local tokens, at = position(cmdline, cursorpos)

    if at <= 2 then
        local names = vim.tbl_keys(handlers)

        table.sort(names)

        return vim.tbl_filter(function(name)
            return vim.startswith(name, arglead)
        end, names)
    end

    local handler = handlers[tokens[2]]

    if handler and handler.complete then
        return handler.complete(arglead, cmdline, cursorpos)
    end

    return {}
end

function M.setup(handlers)
    vim.api.nvim_create_user_command("Outpost", function(opts)
        dispatch(handlers, opts.fargs, opts.bang)
    end, {
        nargs = "+",
        bang = true,
        complete = function(arglead, cmdline, cursorpos)
            return complete(handlers, arglead, cmdline, cursorpos)
        end,
    })
end

return M
