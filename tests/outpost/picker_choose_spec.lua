-- Unit spec for picker selection (offline: vim.ui is stubbed, no probes or
-- ssh).

local picker = require "outpost.picker"

local stub = require "luassert.stub"

describe("picker choose", function()
    local select_stub
    local input_stub
    local notify_stub

    before_each(function()
        select_stub = stub(vim.ui, "select")
        input_stub = stub(vim.ui, "input")
        notify_stub = stub(vim, "notify")
    end)

    after_each(function()
        select_stub:revert()
        input_stub:revert()
        notify_stub:revert()
    end)

    local function session_entry()
        return {
            kind = "session",
            session_id = "00ac56",
            target = "dev@devbox:~/proj",
            state = "live",
            label = "00ac56  dev@devbox:~/proj (live)",
        }
    end

    it("tells the user plainly when there is nothing to pick", function()
        local ran = false

        picker.choose({}, {}, function()
            ran = true
        end)

        assert.stub(select_stub).was_not_called()
        assert.equal(false, ran)
        assert.stub(notify_stub).was_called(1)
        assert.truthy(notify_stub.calls[1].refs[1]:find("no sessions or hosts", 1, true))
    end)

    it("runs the full up flow for the chosen session", function()
        select_stub.invokes(function(items, _, callback)
            callback(items[1])
        end)

        local ran

        picker.choose({ session_entry() }, {}, function(target)
            ran = target
        end)

        assert.equal("dev@devbox:~/proj", ran)
    end)

    it("does nothing when the selection is cancelled", function()
        select_stub.invokes(function(_, _, callback)
            callback(nil)
        end)

        local ran = false

        picker.choose({ session_entry() }, {}, function()
            ran = true
        end)

        assert.equal(false, ran)
    end)

    it("prompts for a path and resolves the user for a chosen host", function()
        select_stub.invokes(function(items, _, callback)
            callback(items[1])
        end)
        input_stub.invokes(function(_, callback)
            callback "/srv/proj"
        end)

        local ran

        picker.choose({
            { kind = "host", host = "devbox", label = "devbox  (ssh-config host)" },
        }, {
            resolve_host = function(host, callback)
                callback("dev@10.0.0.4", nil)
            end,
        }, function(target)
            ran = target
        end)

        assert.equal("dev@devbox:/srv/proj", ran)
    end)

    it("does nothing when the path prompt is cancelled", function()
        select_stub.invokes(function(items, _, callback)
            callback(items[1])
        end)
        input_stub.invokes(function(_, callback)
            callback(nil)
        end)

        local ran = false

        picker.choose({
            { kind = "host", host = "devbox", label = "devbox  (ssh-config host)" },
        }, {
            resolve_host = function(_, callback)
                callback("dev@10.0.0.4", nil)
            end,
        }, function()
            ran = true
        end)

        assert.equal(false, ran)
    end)

    it("reports a host that cannot be resolved instead of running up", function()
        select_stub.invokes(function(items, _, callback)
            callback(items[1])
        end)
        input_stub.invokes(function(_, callback)
            callback "/srv/proj"
        end)

        local ran = false

        picker.choose({
            { kind = "host", host = "devbox", label = "devbox  (ssh-config host)" },
        }, {
            resolve_host = function(_, callback)
                callback(nil, "ssh -G failed")
            end,
        }, function()
            ran = true
        end)

        assert.equal(false, ran)
        assert.truthy(notify_stub.calls[1].refs[1]:find("ssh -G failed", 1, true))
    end)
end)
