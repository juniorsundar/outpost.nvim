-- Unit spec for the attach command presentation (offline, headless).

local present = require "outpost.present"

local COMMAND = "/cache/outpost/attach/ab12cd.sh"

-- Deterministic system clipboard: the real provider would be an OSC52 round
-- trip that headless CI has no terminal to answer.
local clipboard = {}

vim.g.clipboard = {
    name = "outpost-test-clipboard",
    copy = {
        ["+"] = function(lines)
            clipboard["+"] = table.concat(lines, "\n")
        end,
    },
    paste = {
        ["+"] = function()
            return { clipboard["+"] or "" }
        end,
    },
}

vim.cmd "runtime autoload/provider/clipboard.vim"

describe("attach command presentation", function()
    local win

    after_each(function()
        if win and vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_feedkeys("x", "x", false)
            vim.wait(1000, function()
                return not vim.api.nvim_win_is_valid(win)
            end)
        end

        win = nil
    end)

    it("yanks the command into the unnamed register", function()
        present.yank(COMMAND)
        assert.equal(COMMAND, vim.fn.getreg '"')
    end)

    it("yanks the command into the system clipboard", function()
        present.yank(COMMAND)
        assert.equal(COMMAND, vim.fn.getreg "+")
    end)

    it("shows the command in a floating window and yanks it", function()
        win = present.show(COMMAND)

        assert.truthy(vim.api.nvim_win_is_valid(win))
        assert.equal("editor", vim.api.nvim_win_get_config(win).relative)
        assert.are.same({ COMMAND }, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false))
        assert.equal(COMMAND, vim.fn.getreg '"')
    end)

    it("dismisses the window on 'q' and returns to the previous window", function()
        local before = vim.api.nvim_get_current_win()

        win = present.show(COMMAND)

        assert.truthy(vim.api.nvim_win_is_valid(win))

        vim.api.nvim_feedkeys("q", "x", false)

        assert.truthy(
            vim.wait(1000, function()
                return not vim.api.nvim_win_is_valid(win)
            end),
            "the window must dismiss on 'q'"
        )

        win = nil
        assert.equal(before, vim.api.nvim_get_current_win())
    end)

    it("leaves other keys alone, so the command can still be yanked with y/yy", function()
        win = present.show(COMMAND)

        vim.fn.setreg('"', "")
        vim.api.nvim_feedkeys("yy", "x", false)
        vim.wait(100)

        assert.truthy(vim.api.nvim_win_is_valid(win), "a non-'q' key must not dismiss the window")
        -- yy is linewise: the register carries a trailing newline by design
        assert.equal(COMMAND, vim.trim(vim.fn.getreg '"'))
    end)
end)
