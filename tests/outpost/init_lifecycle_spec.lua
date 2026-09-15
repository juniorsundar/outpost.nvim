-- Unit specs for the lifecycle command wiring in init.lua: bare-picker
-- fallback for stop/down, bang threading, and dispatch routing (offline).

local init = require "outpost"

local stub = require "luassert.stub"

describe("bare stop", function()
    local notify_stub

    before_each(function()
        notify_stub = stub(vim, "notify")
    end)

    after_each(function()
        notify_stub:revert()
    end)

    it("opens the picker and reports an empty state instead of erroring", function()
        local dir = vim.fn.tempname()

        vim.fn.mkdir(dir, "p")

        init.stop("", false, { registry_dir = dir })

        assert.stub(notify_stub).was_called()
        assert.truthy(notify_stub.calls[1].refs[1]:find("no sessions to stop", 1, true))

        vim.fn.delete(dir, "rf")
    end)
end)

describe("bare down", function()
    local notify_stub

    before_each(function()
        notify_stub = stub(vim, "notify")
    end)

    after_each(function()
        notify_stub:revert()
    end)

    it("opens the picker and reports an empty state instead of erroring", function()
        local dir = vim.fn.tempname()

        vim.fn.mkdir(dir, "p")

        init.down("", false, { registry_dir = dir })

        assert.stub(notify_stub).was_called()
        assert.truthy(notify_stub.calls[1].refs[1]:find("no known outposts", 1, true))

        vim.fn.delete(dir, "rf")
    end)
end)
