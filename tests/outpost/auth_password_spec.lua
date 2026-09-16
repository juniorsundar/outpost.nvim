-- Integration tests: the askpass bridge against a real sshd, over the
-- fixture's password-authenticating account, gated on the fixture being up
-- (pending, not failing, without docker). The prompt handler is stubbed at
-- the auth.lua seam, so the bridge and the ssh interaction are tested, not
-- Neovim's input UI.

local auth = require "outpost.auth"
local transport = require "outpost.transport"
local up = require "outpost.up"

local harness = require "outpost.harness"
local await = require "outpost.await"
local stub = require "luassert.stub"

describe("the askpass bridge against a real sshd", function()
    local prompt_stub
    local old_display
    local old_agent
    local cache_dir
    local client_dir

    before_each(function()
        if not harness.pending_unless_up() then
            return
        end

        -- a password-only outpost means no keys: drop the agent so its keys
        -- cannot exhaust sshd's MaxAuthTries before password auth is reached
        old_display = vim.env.DISPLAY
        old_agent = vim.env.SSH_AUTH_SOCK
        vim.env.DISPLAY = nil
        vim.env.SSH_AUTH_SOCK = nil

        prompt_stub = stub(auth, "prompt")
    end)

    after_each(function()
        if prompt_stub then
            prompt_stub:revert()
        end

        vim.env.DISPLAY = old_display
        vim.env.SSH_AUTH_SOCK = old_agent
    end)

    -- Run a command on the fixture as the password account, through the
    -- bridge itself (the account has no key). Never muxed, so setup leaves
    -- no master behind to warm a later test's connection.
    local function pass_remote(command, conn)
        return unpack(await(
            transport.run,
            15000,
            harness.pass_target(),
            command,
            vim.tbl_extend("force", {
                port = harness.port(),
                known_hosts = harness.known_hosts(),
                mux = false,
                askpass = true,
            }, conn or {})
        ))
    end

    it("completes a real ssh with no tty and no DISPLAY when the prompt returns the fixture password", function()
        if not harness.pending_unless_up() then
            return
        end

        prompt_stub.invokes(function(kind, text, callback)
            callback(harness.password())
        end)

        local code, out = unpack(
            await(
                transport.run,
                15000,
                harness.pass_target(),
                "echo bridge-$((30 + 12))",
                { port = harness.port(), known_hosts = harness.known_hosts(), mux = false, askpass = true }
            )
        )

        assert.equal(0, code)
        assert.equal("bridge-42", vim.trim(out))
        assert.equal(1, #prompt_stub.calls)
        assert.equal("secret", prompt_stub.calls[1].vals[1])
        assert.matches("password", prompt_stub.calls[1].vals[2], 1, true)
    end)

    it("fails a wrong password cleanly with one prompt and one failure", function()
        if not harness.pending_unless_up() then
            return
        end

        prompt_stub.invokes(function(_, _, callback)
            callback "definitely-not-the-password"
        end)

        local code, _, err = unpack(
            await(
                transport.run,
                15000,
                harness.pass_target(),
                "true",
                { port = harness.port(), known_hosts = harness.known_hosts(), mux = false, askpass = true }
            )
        )

        assert.are_not.equal(0, code)
        assert.equal(1, #prompt_stub.calls)
        assert.matches("Permission denied", err, 1, true)
    end)

    it("takes a full up against the password account with exactly one credential prompt", function()
        if not harness.pending_unless_up() then
            return
        end

        prompt_stub.invokes(function(_, _, callback)
            callback(harness.password())
        end)

        -- a fresh outpost and a cold mux path, so the priming has to happen
        -- inside this flow
        pass_remote("pkill -u " .. harness.pass_user() .. " -f nvim; rm -rf $HOME/.cache/outpost")
        pass_remote "mkdir -p $HOME/proj"

        local registry_dir = vim.fn.tempname()
        local attach_dir = vim.fn.tempname()
        local mux_path = vim.fn.tempname() .. "/mux/%C"

        -- the download and pinned-client caches are keyed by tag, so one
        -- directory serves every test in this file
        cache_dir = cache_dir or vim.fn.tempname()
        client_dir = client_dir or vim.fn.tempname()

        local before = #prompt_stub.calls

        local result, err = unpack(await(up.run, 240000, harness.pass_target() .. ":~/proj", {
            conn = {
                port = harness.port(),
                known_hosts = harness.known_hosts(),
                mux_path = mux_path,
                askpass = true,
            },
            registry_dir = registry_dir,
            cache_dir = cache_dir,
            client_dir = client_dir,
            attach_dir = attach_dir,
        }))

        assert.truthy(result, err)
        assert.equal(1, #prompt_stub.calls - before, "one password, not one per connection")

        vim.fn.delete(registry_dir, "rf")
        vim.fn.delete(attach_dir, "rf")
    end)

    it("aborts a full up when the prompt is cancelled - one prompt, one failure, no cascade", function()
        if not harness.pending_unless_up() then
            return
        end

        -- setup needs a real authentication; only the operation under test
        -- is cancelled
        local cancelling = false

        prompt_stub.invokes(function(_, _, callback)
            if cancelling then
                callback(nil)
                return
            end

            callback(harness.password())
        end)

        pass_remote("pkill -u " .. harness.pass_user() .. " -f nvim; rm -rf $HOME/.cache/outpost")
        pass_remote "mkdir -p $HOME/proj"

        cancelling = true

        local registry_dir = vim.fn.tempname()
        local attach_dir = vim.fn.tempname()
        local mux_path = vim.fn.tempname() .. "/mux/%C"

        local reported = {}
        local real_notify = vim.notify

        vim.notify = function(msg, level)
            table.insert(reported, { msg = msg, level = level })
        end

        local before = #prompt_stub.calls

        local result, err = unpack(await(up.run, 60000, harness.pass_target() .. ":~/proj", {
            conn = {
                port = harness.port(),
                known_hosts = harness.known_hosts(),
                mux_path = mux_path,
                askpass = true,
            },
            registry_dir = registry_dir,
            cache_dir = cache_dir,
            client_dir = client_dir,
            attach_dir = attach_dir,
        }))

        vim.notify = real_notify

        assert.falsy(result)
        assert.matches("cancelled", err, 1, true)
        assert.equal(1, #prompt_stub.calls - before, "cancel must not raise a second prompt")

        local errors = vim.tbl_filter(function(n)
            return n.level == vim.log.levels.ERROR
        end, reported)

        assert.equal(1, #errors, "one failure, not a cascade of per-connection failures")

        vim.fn.delete(registry_dir, "rf")
        vim.fn.delete(attach_dir, "rf")
    end)

    it("never blocks the default headless path on a prompt", function()
        if not harness.pending_unless_up() then
            return
        end

        -- no askpass override: headless nvim must fall through to BatchMode,
        -- fail fast, and leave the prompt handler untouched
        local code, _, err = unpack(
            await(
                transport.run,
                15000,
                harness.pass_target(),
                "true",
                { port = harness.port(), known_hosts = harness.known_hosts(), mux = false }
            )
        )

        assert.are_not.equal(0, code)
        assert.matches("Permission denied", err, 1, true)
        assert.equal(0, #prompt_stub.calls)
    end)
end)
