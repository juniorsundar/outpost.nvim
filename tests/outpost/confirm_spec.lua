-- Unit spec for the shared yes/no confirmation helper (offline: vim.ui is
-- stubbed, no probes or ssh).

local confirm = require "outpost.confirm"

local stub = require "luassert.stub"

describe("confirm", function()
    local select_stub

    before_each(function()
        select_stub = stub(vim.ui, "select")
    end)

    after_each(function()
        select_stub:revert()
    end)

    it("skips the prompt and calls back true when banged", function()
        local answered

        confirm.ask("destroy it?", { bang = true }, function(ok)
            answered = ok
        end)

        assert.stub(select_stub).was_not_called()
        assert.is_true(answered)
    end)

    it("prompts yes/no and calls back true on yes", function()
        select_stub.invokes(function(items, _, callback)
            callback(items[1])
        end)

        local answered

        confirm.ask("destroy it?", {}, function(ok)
            answered = ok
        end)

        assert.stub(select_stub).was_called(1)
        assert.equal("destroy it?", select_stub.calls[1].refs[2].prompt)
        assert.is_true(answered)
    end)

    it("calls back false on no", function()
        select_stub.invokes(function(items, _, callback)
            callback(items[2])
        end)

        local answered

        confirm.ask("destroy it?", {}, function(ok)
            answered = ok
        end)

        assert.is_false(answered)
    end)

    it("calls back false when the prompt is cancelled", function()
        select_stub.invokes(function(_, _, callback)
            callback(nil)
        end)

        local answered

        confirm.ask("destroy it?", {}, function(ok)
            answered = ok
        end)

        assert.is_false(answered)
    end)
end)
