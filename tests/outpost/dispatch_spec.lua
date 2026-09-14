-- Unit spec for command dispatch (offline: vim.api only, no network).

local dispatch = require "outpost.dispatch"

describe("command dispatch", function()
    it("exposes Outpost and OutpostUpdate as user commands", function()
        local called = {}

        dispatch.setup {
            probe = function(arg)
                called.probe = arg
            end,
            update = function(arg)
                called.update = arg
            end,
        }

        local commands = vim.api.nvim_get_commands {}

        assert.truthy(commands["Outpost"])
        assert.truthy(commands["OutpostUpdate"])
        assert.equal("1", commands["Outpost"].nargs)
        assert.equal("1", commands["OutpostUpdate"].nargs)
    end)

    it("routes a target argument to the matching handler", function()
        local called = {}

        dispatch.setup {
            probe = function(arg)
                called.probe = arg
            end,
            update = function(arg)
                called.update = arg
            end,
        }

        vim.api.nvim_cmd({ cmd = "Outpost", args = { "user@host" } }, {})
        vim.api.nvim_cmd({ cmd = "OutpostUpdate", args = { "user@host" } }, {})

        assert.equal("user@host", called.probe)
        assert.equal("user@host", called.update)
    end)
end)
