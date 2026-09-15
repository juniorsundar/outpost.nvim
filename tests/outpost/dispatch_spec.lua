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

describe("command completion", function()
    it("offers subcommands for the first argument", function()
        dispatch.setup {
            up = {
                run = function() end,
                complete = function()
                    return { "target" }
                end,
            },
            update = {
                run = function() end,
                complete = function()
                    return { "host" }
                end,
            },
        }

        assert.are_same({ "up", "update" }, vim.fn.getcompletion("Outpost ", "cmdline"))
    end)

    it("delegates the argument to the subcommand's completion", function()
        dispatch.setup {
            up = {
                run = function() end,
                complete = function(arglead)
                    return { "target-" .. arglead }
                end,
            },
            update = { run = function() end },
        }

        assert.are_same({ "target-" }, vim.fn.getcompletion("Outpost up ", "cmdline"))
    end)

    it("offers nothing for a subcommand without a completion", function()
        dispatch.setup {
            up = { run = function() end },
            update = { run = function() end },
        }

        assert.are_same({}, vim.fn.getcompletion("Outpost up ", "cmdline"))
    end)

    it("passes false when the command is not banged", function()
        local received

        dispatch.setup {
            up = {
                run = function(_, bang)
                    received = bang
                end,
            },
        }

        vim.api.nvim_cmd({ cmd = "Outpost", args = { "up", "dev@box:~/proj" } }, {})

        assert.is_false(received)
    end)

    it("passes true when the command is banged", function()
        local received

        dispatch.setup {
            up = {
                run = function(_, bang)
                    received = bang
                end,
            },
        }

        vim.api.nvim_cmd({ cmd = "Outpost", args = { "up", "dev@box:~/proj" }, bang = true }, {})

        assert.is_true(received)
    end)

    it("routes a table handler's run", function()
        local called

        dispatch.setup {
            up = {
                run = function(arg)
                    called = arg
                end,
            },
        }

        vim.api.nvim_cmd({ cmd = "Outpost", args = { "up", "dev@box:~/proj" } }, {})

        assert.equal("dev@box:~/proj", called)
    end)
end)
