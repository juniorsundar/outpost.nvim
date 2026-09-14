-- Unit spec for command dispatch (offline: vim.api only, no network).
--
-- One user command, subcommand dispatch: `:Outpost up <target>` and
-- `:Outpost update <host>`. The old `OutpostUpdate` command name no longer
-- exists (ticket 02).

local dispatch = require "outpost.dispatch"

describe("command dispatch", function()
    it("exposes Outpost; the old OutpostUpdate name no longer exists", function()
        dispatch.setup {
            up = function() end,
            update = function() end,
        }

        local commands = vim.api.nvim_get_commands {}

        assert.truthy(commands["Outpost"])
        assert.falsy(commands["OutpostUpdate"])
    end)

    it("routes `up` with its target argument to the up handler", function()
        local called = {}

        dispatch.setup {
            up = function(arg)
                called.up = arg
            end,
            update = function() end,
        }

        vim.api.nvim_cmd({ cmd = "Outpost", args = { "up", "dev@box:~/code/proj" } }, {})

        assert.equal("dev@box:~/code/proj", called.up)
    end)

    it("routes `update` with its host argument to the update handler", function()
        local called = {}

        dispatch.setup {
            up = function() end,
            update = function(arg)
                called.update = arg
            end,
        }

        vim.api.nvim_cmd({ cmd = "Outpost", args = { "update", "dev@box" } }, {})

        assert.equal("dev@box", called.update)
    end)

    it("rejects an unknown subcommand", function()
        dispatch.setup {
            up = function() end,
            update = function() end,
        }

        local ok, err = pcall(vim.api.nvim_cmd, { cmd = "Outpost", args = { "frobnicate", "x" } }, {})

        assert.falsy(ok)
        assert.matches("unknown subcommand: frobnicate", err)
    end)

    it("rejects a missing subcommand", function()
        dispatch.setup {
            up = function() end,
            update = function() end,
        }

        local ok, err = pcall(vim.api.nvim_cmd, { cmd = "Outpost", args = {} }, { nargs = "+" })

        assert.falsy(ok)
    end)
end)
