-- Presentation of the attach command: a floating window with the command,
-- yanked into the unnamed and system clipboard registers, dismissed by any
-- key.

local M = {}

-- A headless or provider-less nvim has no system clipboard; that must never
-- fail the handout, so only the unnamed register is mandatory.
function M.yank(command)
    vim.fn.setreg('"', command)
    pcall(vim.fn.setreg, "+", command)
end

local function dismiss(win, buf)
    if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
    end

    if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
    end
end

-- Show the command and arm dismissal on the next keypress. Returns the
-- floating window.
function M.show(command)
    M.yank(command)

    local buf = vim.api.nvim_create_buf(false, true)

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { command })
    vim.bo[buf].modifiable = false

    local width = math.min(math.max(#command + 4, 20), math.max(vim.o.columns - 4, 20))
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        style = "minimal",
        border = "rounded",
        title = " outpost attach ",
        width = width,
        height = 1,
        row = math.max(math.floor(vim.o.lines / 2) - 1, 0),
        col = math.max(math.floor((vim.o.columns - width) / 2), 0),
    })

    local ns

    ns = vim.on_key(function(key)
        if key == "" then
            return
        end

        vim.on_key(nil, ns)
        vim.schedule(function()
            dismiss(win, buf)
        end)

        -- swallow the dismissing key so it cannot leak into a buffer
        return ""
    end)

    return win
end

return M
