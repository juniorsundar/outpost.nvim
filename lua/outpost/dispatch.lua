-- Command dispatch: registers the user commands and routes their target
-- argument to the matching handler.

local M = {}

function M.setup(handlers)
    local function command_opts()
        return {
            nargs = 1,
        }
    end

    vim.api.nvim_create_user_command("Outpost", function(opts)
        handlers.probe(opts.args)
    end, command_opts())

    vim.api.nvim_create_user_command("OutpostUpdate", function(opts)
        handlers.update(opts.args)
    end, command_opts())
end

return M
