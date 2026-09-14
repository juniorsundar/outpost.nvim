-- Unit spec for the bare-`up` entry point (offline: empty sources, no
-- probes).

local init = require "outpost"

local stub = require "luassert.stub"

describe("bare up", function()
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

        init.up("", { registry_dir = dir, ssh_config = dir .. ".none" })

        assert.stub(notify_stub).was_called()
        assert.truthy(notify_stub.calls[1].refs[1]:find("no sessions or hosts", 1, true))

        vim.fn.delete(dir, "rf")
    end)
end)
