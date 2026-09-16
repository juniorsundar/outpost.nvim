-- Presentation floats: the attach command handout and the read-only
-- report. Both are read-only scratch buffers in a centered floating
-- window, yanked when asked, dismissed by 'q'; every other key passes
-- through untouched so the content can still be yanked first.

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

-- One floating window over the lines: read-only, centered, 'q'-dismissed.
-- `yank` (optional) is set into the registers before the window opens.
-- Returns the window.
local function float(lines, opts)
    if opts.yank then
        M.yank(opts.yank)
    end

    local buf = vim.api.nvim_create_buf(false, true)

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    local longest = 20

    for _, line in ipairs(lines) do
        longest = math.max(longest, #line)
    end

    local width = math.min(longest + 4, math.max(vim.o.columns - 4, 20))
    local height = math.min(math.max(#lines, 1), math.max(vim.o.lines - 4, 1))
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        style = "minimal",
        border = "rounded",
        title = opts.title,
        width = width,
        height = height,
        row = math.max(math.floor((vim.o.lines - height) / 2), 0),
        col = math.max(math.floor((vim.o.columns - width) / 2), 0),
    })

    vim.keymap.set("n", "q", function()
        dismiss(win, buf)
    end, { buffer = buf, nowait = true, silent = true })

    return win
end

function M.show(command)
    return float({ command }, { title = " outpost attach ", yank = command })
end

function M.report(lines, title)
    return float(lines, { title = title or " outpost sessions " })
end

return M
