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

    it("dismisses the window on any key and returns to the previous window", function()
        local before = vim.api.nvim_get_current_win()

        win = present.show(COMMAND)

        assert.truthy(vim.api.nvim_win_is_valid(win))

        vim.api.nvim_feedkeys("x", "x", false)

        assert.truthy(
            vim.wait(1000, function()
                return not vim.api.nvim_win_is_valid(win)
            end),
            "the window must dismiss on a keypress"
        )

        win = nil
        assert.equal(before, vim.api.nvim_get_current_win())
    end)

    it("unregisters its dismissal handler after the first key", function()
        -- count how often present's on_key callback runs: a stale handler
        -- would keep firing (and eat every later key)
        local fires = 0
        local real = vim.on_key

        vim.on_key = function(...)
            local args = { ... }

            if args[1] then
                local fn = args[1]

                args[1] = function(key)
                    fires = fires + 1
                    return fn(key)
                end
            end

            return real(unpack(args))
        end

        win = present.show(COMMAND)

        vim.api.nvim_feedkeys("x", "x", false)
        assert.truthy(vim.wait(1000, function()
            return not vim.api.nvim_win_is_valid(win)
        end))

        vim.api.nvim_feedkeys("y", "x", false)
        vim.wait(200)

        vim.on_key = real

        assert.equal(1, fires, "the dismissal handler must be a one-shot")
    end)
end)
