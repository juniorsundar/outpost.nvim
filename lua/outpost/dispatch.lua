-- Command dispatch: registers the single user command and routes
-- subcommands (`up`, `update`) to their handlers.

local M = {}

local function dispatch(handlers, fargs)
    local subcommand = fargs[1]
    local argument = table.concat(fargs, " ", 2)

    local handler = handlers[subcommand]

    if not handler then
        error(("outpost: unknown subcommand: %s"):format(subcommand or ""))
    end

    handler(argument)
end

function M.setup(handlers)
    vim.api.nvim_create_user_command("Outpost", function(opts)
        dispatch(handlers, opts.fargs)
    end, {
        nargs = "+",
    })
end

return M
