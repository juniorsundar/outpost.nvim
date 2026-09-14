-- Integration spec: `up` takes over a session that already has a UI attached
-- - no refuse path. The UI is simulated headlessly: a plain RPC channel that
-- calls nvim_ui_attach, then records the moment its channel is closed.

local up = require "outpost.up"
local session = require "outpost.session"

local harness = require "outpost.harness"
local await = require "outpost.await"

local CLIENT_SCRIPT = [[
local chan = vim.fn.sockconnect("pipe", vim.env.OUTPOST_UI_SOCK, { rpc = true })
vim.rpcrequest(chan, "nvim_ui_attach", 80, 24, {})
local attached = assert(io.open(vim.env.OUTPOST_UI_ATTACHED, "w"))
attached:write(chan)
attached:close()
vim.wait(60000, function()
    local info = vim.api.nvim_get_chan_info(chan)
    return info == nil or next(info) == nil
end, 100)
local closed = assert(io.open(vim.env.OUTPOST_UI_CLOSED, "w"))
closed:write("closed")
closed:close()
]]

describe("up takeover", function()
    local opts
    local registry_dir
    local client_dir
    local attach_dir

    before_each(function()
        if not harness.pending_unless_up() then
            return
        end

        registry_dir = vim.fn.tempname()
        vim.fn.mkdir(registry_dir, "p")
        client_dir = client_dir or vim.fn.tempname()
        attach_dir = vim.fn.tempname()

        opts = {
            conn = {
                port = harness.port(),
                key = harness.key(),
                known_hosts = harness.known_hosts(),
            },
            registry_dir = registry_dir,
            client_dir = client_dir,
            attach_dir = attach_dir,
        }

        harness.remote "mkdir -p $HOME/proj"
    end)

    after_each(function()
        if not registry_dir then
            return
        end

        vim.fn.delete(registry_dir, "rf")
        vim.fn.delete(attach_dir, "rf")

        -- a failed run must not leave a simulated UI client behind
        harness.remote "pkill -f outpost-ui-client.lua >/dev/null 2>&1 || true"
        harness.remote "rm -f /tmp/outpost-ui-client.lua /tmp/outpost-ui-attached /tmp/outpost-ui-closed /tmp/outpost-ui-client.log"
    end)

    -- Attach the simulated UI to the session's socket on the fixture and
    -- return once the attach is observable.
    local function attach_simulated_ui(sid)
        local home = vim.trim(harness.remote('printf %s "$HOME"').out)
        local socket = session.paths(sid).socket:gsub("%$HOME", home)

        assert.equal(
            0,
            harness.remote(("cat > /tmp/outpost-ui-client.lua <<'LUA'\n%s\nLUA"):format(CLIENT_SCRIPT)).code
        )

        local command = ([[
OUTPOST_UI_SOCK='%s' \
OUTPOST_UI_ATTACHED=/tmp/outpost-ui-attached \
OUTPOST_UI_CLOSED=/tmp/outpost-ui-closed \
nohup "$HOME/.cache/outpost/install/current/bin/nvim" --headless --clean \
    -l /tmp/outpost-ui-client.lua >/tmp/outpost-ui-client.log 2>&1 </dev/null &
]]):format(socket)

        assert.equal(0, harness.remote(command).code)

        for _ = 1, 50 do
            if harness.remote("test -f /tmp/outpost-ui-attached").code == 0 then
                return
            end

            vim.wait(100)
        end

        assert.falsy(
            true,
            "the simulated UI never attached: " .. harness.remote("cat /tmp/outpost-ui-client.log 2>/dev/null").out
        )
    end

    it("closes an attached UI and still proceeds - no refuse path", function()
        if not harness.pending_unless_up() then
            return
        end

        -- ensure a live session
        local first, first_err = unpack(await(up.run, 180000, "outpost@127.0.0.1:~/proj", opts))

        assert.truthy(first, first_err)

        local sid = first.session_id

        attach_simulated_ui(sid)

        -- the server sees the attached UI before takeover
        local before = await(session.query, 30000, first.endpoint, sid, "json_encode(nvim_list_uis())", opts)[1]

        assert.truthy(before and before ~= "[]", "the simulated UI should be attached: " .. tostring(before))

        local reported = {}
        local real_notify = vim.notify

        vim.notify = function(msg, level)
            table.insert(reported, { msg = msg, level = level })
        end

        local second, second_err = unpack(await(up.run, 120000, "outpost@127.0.0.1:~/proj", opts))

        vim.notify = real_notify

        -- no refusal: up proceeds with its result
        assert.truthy(second, second_err)

        -- the simulated channel observed the close
        local closed

        for _ = 1, 50 do
            closed = harness.remote "cat /tmp/outpost-ui-closed 2>/dev/null"

            if closed.code == 0 then
                break
            end

            vim.wait(100)
        end

        assert.equal(0, closed.code, "the simulated UI never observed its channel closing")
        assert.equal("closed", vim.trim(closed.out))

        -- the server has no UI left
        local after = await(session.query, 30000, first.endpoint, sid, "json_encode(nvim_list_uis())", opts)[1]

        assert.equal("[]", after)

        -- the user is told the UI was detached
        local detach

        for _, entry in ipairs(reported) do
            if entry.msg:find("detached", 1, true) then
                detach = entry
            end
        end

        assert.truthy(detach, "up should notify that a UI was detached")
        assert.truthy(detach.msg:find(sid, 1, true))
        assert.equal(vim.log.levels.WARN, detach.level)
    end)
end)
