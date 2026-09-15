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

describe("session mode", function()
    local real_session
    local real_clipboard
    local send
    local request

    before_each(function()
        real_session = vim.env.OUTPOST_SESSION
        real_clipboard = vim.g.clipboard
        send = nil
        request = nil
        vim.env.OUTPOST_SESSION = "1"
        pcall(vim.api.nvim_del_user_command, "Outpost")
    end)

    after_each(function()
        vim.env.OUTPOST_SESSION = real_session
        vim.g.clipboard = real_clipboard
        pcall(vim.api.nvim_del_user_command, "Outpost")

        if send then
            send:revert()
        end

        if request then
            request:revert()
        end
    end)

    it("registers no user command", function()
        init.setup {}

        assert.is_nil(vim.api.nvim_get_commands({})["Outpost"])
    end)

    it("ships the OSC52 clipboard branch", function()
        send = stub(vim.api, "nvim_ui_send")
        request = stub(vim.tty, "request")

        request.returns(1)
        request.invokes(function(_, _, callback)
            callback "\027]52;c;aGVsbG8=\027\\"
        end)

        init.setup {}

        vim.g.clipboard.copy["+"] { "hello" }
        vim.g.clipboard.copy["*"] { "hello" }

        assert.stub(send).was_called_with "\027]52;c;aGVsbG8=\027\\"
        assert.stub(send).was_called_with "\027]52;p;aGVsbG8=\027\\"

        assert.are_same({ "hello" }, vim.g.clipboard.paste["+"]())
        assert.are_same({ "hello" }, vim.g.clipboard.paste["*"]())
    end)

    it("opts out of the session branch", function()
        vim.g.clipboard = { name = "user-provided" }

        init.setup { session = false }

        assert.equal("user-provided", vim.g.clipboard.name)
        assert.is_nil(vim.api.nvim_get_commands({})["Outpost"])
    end)
end)

describe("outside a session", function()
    local real_session

    before_each(function()
        real_session = vim.env.OUTPOST_SESSION
        vim.env.OUTPOST_SESSION = nil
        pcall(vim.api.nvim_del_user_command, "Outpost")
    end)

    after_each(function()
        vim.env.OUTPOST_SESSION = real_session
        pcall(vim.api.nvim_del_user_command, "Outpost")
    end)

    it("registers the user command", function()
        init.setup {}

        assert.truthy(vim.api.nvim_get_commands({})["Outpost"])
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

describe("sync wiring", function()
    local complete = require "outpost.complete"
    local sync = require "outpost.sync"

    local run_stub
    local select_stub

    before_each(function()
        vim.env.OUTPOST_SESSION = nil
        pcall(vim.api.nvim_del_user_command, "Outpost")
        init.setup {}
        run_stub = stub(sync, "run")
        select_stub = stub(vim.ui, "select")
    end)

    after_each(function()
        run_stub:revert()
        select_stub:revert()
        pcall(vim.api.nvim_del_user_command, "Outpost")
    end)

    it("routes `sync` with its host argument to the sync flow", function()
        vim.api.nvim_cmd({ cmd = "Outpost", args = { "sync", "box" } }, {})

        assert.equal("box", run_stub.calls[1].refs[1])
        assert.is_false(run_stub.calls[1].refs[2].bang)
    end)

    it("threads the bang into sync, where it stays inert", function()
        vim.api.nvim_cmd({ cmd = "Outpost", args = { "sync", "box" }, bang = true }, {})

        assert.equal(true, run_stub.calls[1].refs[2].bang)
        assert.stub(select_stub).was_not_called()
    end)

    it("does not run a bare sync before a host exists", function()
        local notify_stub = stub(vim, "notify")

        vim.api.nvim_cmd({ cmd = "Outpost", args = { "sync" } }, {})

        assert.stub(run_stub).was_not_called()
        assert.stub(notify_stub).was_called()

        notify_stub:revert()
    end)

    it("completes the sync argument with known hosts", function()
        local hosts_stub = stub(complete, "hosts")

        vim.fn.getcompletion("Outpost sync ", "cmdline")

        assert.stub(hosts_stub).was_called()

        hosts_stub:revert()
    end)
end)
