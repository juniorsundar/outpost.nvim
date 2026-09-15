-- Shared yes/no confirmation for destructive commands, skippable with a
-- bang.

local M = {}

-- callback(ok). Banged calls skip the prompt entirely and call back true.
function M.ask(message, opts, callback)
    opts = opts or {}

    if opts.bang then
        callback(true)
        return
    end

    vim.ui.select({ "Yes", "No" }, { prompt = message }, function(choice)
        callback(choice == "Yes")
    end)
end

return M
