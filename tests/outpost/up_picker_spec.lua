-- Integration spec: bare `up` opens the picker over the fixture's registry
-- sessions; selecting a live one runs the full `up` path and presents the
-- attach command as usual. Gated on the docker-sshd fixture.

local init = require "outpost"
local attach = require "outpost.attach"
local picker = require "outpost.picker"
local present = require "outpost.present"
local up = require "outpost.up"

local harness = require "outpost.harness"
local await = require "outpost.await"

describe("up picker", function()
    local opts
    local attach_dir

    local real_select
    local real_present
    local real_notify

    before_each(function()
        if not harness.pending_unless_up() then
            return
        end

        attach_dir = vim.fn.tempname()

        local registry_dir = vim.fn.tempname()
        local cache_dir = vim.fn.tempname()

        vim.fn.mkdir(registry_dir, "p")

        opts = {
            conn = {
                port = harness.port(),
                key = harness.key(),
                known_hosts = harness.known_hosts(),
            },
            registry_dir = registry_dir,
            cache_dir = cache_dir,
            attach_dir = attach_dir,
            -- a runnable stand-in for the pinned client: this spec verifies
            -- that the attach command is presented, not the attach itself
            nvim = "/bin/true",
        }

        real_select = vim.ui.select
        real_present = present.show
        real_notify = vim.notify

        harness.remote "mkdir -p $HOME/proj"
    end)

    after_each(function()
        vim.ui.select = real_select
        present.show = real_present
        vim.notify = real_notify

        if opts then
            vim.fn.delete(opts.registry_dir, "rf")
            vim.fn.delete(attach_dir, "rf")
        end
    end)

    it("offers a live registry session and presents its attach command on selection", function()
        if not harness.pending_unless_up() then
            return
        end

        local first, err = unpack(await(up.run, 180000, "outpost@127.0.0.1:~/proj", opts))

        assert.truthy(first, err)

        local sid = first.session_id

        -- the picker is the UI seam: choose the first offered entry
        local offered
        local presented
        local reported = {}

        vim.ui.select = function(entries, _, callback)
            offered = entries
            callback(entries[1])
        end
        present.show = function(command)
            presented = command
        end
        vim.notify = function(msg)
            table.insert(reported, msg)
        end

        picker.pick(opts, function(target)
            init.up(target, opts)
        end)

        assert.truthy(
            vim.wait(120000, function()
                return presented ~= nil
            end),
            "the picker flow never presented the attach command; notifications: " .. vim.inspect(reported)
        )

        -- the picker offered the live session in the target's short-id form
        local session_entry

        for _, entry in ipairs(offered or {}) do
            if entry.kind == "session" and entry.session_id == sid then
                session_entry = entry
            end
        end

        assert.truthy(session_entry, "the picker must offer the live session")
        assert.truthy(session_entry.label:find("(live)", 1, true))
        assert.equal("outpost@127.0.0.1:~/proj", session_entry.target)

        -- selecting it re-entered the full `up` path (idempotent, no refuse)
        local already_live

        for _, msg in ipairs(reported) do
            if msg:find("already live", 1, true) then
                already_live = msg
            end
        end

        assert.truthy(already_live, "selecting the live session must run the full up path")

        -- and the attach command was presented as usual
        assert.equal(attach.path(sid, attach_dir), presented)
    end)
end)
