-- Unit spec for the askpass bridge: prompt-kind discrimination, helper
-- generation, headless detection, and the FIFO round trip against a fake
-- ssh. Offline by construction.

local auth = require "outpost.auth"
local config = require "outpost.config"
local transport = require "outpost.transport"

local await = require "outpost.await"
local stub = require "luassert.stub"

describe("credential prompt discrimination", function()
    it("treats a host-key fingerprint block as a confirmation", function()
        local block = [[The authenticity of host 'box (10.0.0.1)' can't be established.
ED25519 key fingerprint is SHA256:abc123.
This key is not known by any other names.
Are you sure you want to continue connecting (yes/no/[fingerprint])?]]

        assert.equal("confirm", auth.prompt_kind(block))
    end)

    it("treats a password prompt as a secret", function()
        assert.equal("secret", auth.prompt_kind "user@box's password: ")
    end)

    it("treats a key passphrase prompt as a secret", function()
        assert.equal("secret", auth.prompt_kind "Enter passphrase for key '/home/u/.ssh/id_ed25519': ")
    end)

    it("falls back to a secret for unrecognised wording", function()
        assert.equal("secret", auth.prompt_kind "Speak, friend, and enter: ")
    end)

    it("treats a missing prompt as a secret rather than erroring", function()
        assert.equal("secret", auth.prompt_kind(nil))
    end)
end)

describe("askpass bridge installation", function()
    after_each(function()
        config.setup {}
    end)

    it("is off when no UI is attached", function()
        config.setup {}

        assert.falsy(auth.enabled())
    end)

    it("is on when a UI is attached and no override is set", function()
        config.setup {}

        local uis = stub(vim.api, "nvim_list_uis").returns { { chan = 1 } }

        assert.truthy(auth.enabled())

        uis:revert()
    end)

    it("honours an explicit enabling override with no UI attached", function()
        config.setup { askpass = true }

        assert.truthy(auth.enabled())
    end)

    it("honours an explicit disabling override with a UI attached", function()
        config.setup { askpass = false }

        local uis = stub(vim.api, "nvim_list_uis").returns { { chan = 1 } }

        assert.falsy(auth.enabled())

        uis:revert()
    end)

    it("lets a per-connection override win over the config", function()
        config.setup { askpass = false }

        assert.truthy(auth.enabled { askpass = true })
        assert.falsy(auth.enabled { askpass = false })
    end)
end)

describe("askpass helper generation", function()
    local tmp

    before_each(function()
        tmp = vim.fn.tempname()
        vim.fn.mkdir(tmp, "p")
    end)

    after_each(function()
        vim.fn.delete(tmp, "rf")
        config.setup {}
    end)

    local function opts()
        return { askpass_cache = tmp }
    end

    it("is a POSIX sh helper that bridges the two FIFOs", function()
        local script = auth.helper_script()

        assert.truthy(script:find "^#!%s*/bin/sh")
        assert.truthy(script:find("OUTPOST_ASKPASS_ASK", 1, true))
        assert.truthy(script:find("OUTPOST_ASKPASS_ANSWER", 1, true))

        local path = vim.fn.tempname() .. ".sh"

        vim.fn.writefile(vim.split(script, "\n"), path)
        vim.fn.system { "sh", "-n", path }

        local code = vim.v.shell_error

        vim.fn.delete(path)

        assert.equal(0, code, "the helper must be valid POSIX sh")
    end)

    it("names the helper askpass.sh under the outpost cache", function()
        assert.equal(vim.fs.joinpath(tmp, "outpost", "askpass.sh"), auth.helper_path(opts()))
    end)

    it("writes the helper executable, private to the user", function()
        local path = auth.ensure_helper(opts())

        assert.equal(1, vim.fn.executable(path))
        assert.equal(448, vim.uv.fs_stat(path).mode % 512, "the helper must be 0700")
    end)

    it("regenerates the helper when it is missing", function()
        vim.fn.delete(auth.helper_path(opts()))

        local path = auth.ensure_helper(opts())

        assert.truthy(vim.uv.fs_stat(path))
    end)

    it("regenerates a stale helper", function()
        local path = auth.helper_path(opts())

        vim.fn.mkdir(vim.fs.dirname(path), "p")
        vim.fn.writefile({ "#!/bin/sh", "exit 0" }, path)

        auth.ensure_helper(opts())

        assert.equal(
            table.concat(vim.split(auth.helper_script(), "\n"), "\n"),
            vim.trim(table.concat(vim.fn.readfile(path), "\n"))
        )
    end)
end)

describe("askpass bridge env and FIFOs", function()
    local tmp
    local conn

    before_each(function()
        tmp = vim.fn.tempname()
        vim.fn.mkdir(tmp, "p")

        config.setup { askpass = true }

        conn = {
            mux = false,
            askpass = true,
            askpass_cache = tmp,
            askpass_dir = vim.fs.joinpath(tmp, "fifos"),
        }
    end)

    after_each(function()
        config.setup {}
        vim.fn.delete(tmp, "rf")
    end)

    it("returns an env table naming the helper, both FIFOs and a token", function()
        local env, close = auth.env("user@box", conn)

        assert.equal(auth.helper_path(conn), env.SSH_ASKPASS)
        assert.equal("force", env.SSH_ASKPASS_REQUIRE)
        assert.truthy(env.OUTPOST_ASKPASS_ASK)
        assert.truthy(env.OUTPOST_ASKPASS_ANSWER)
        assert.truthy(env.OUTPOST_ASKPASS_TOKEN)
        assert.are_not.equal(env.OUTPOST_ASKPASS_ASK, env.OUTPOST_ASKPASS_ANSWER)

        close()
    end)

    it("creates 0600 FIFOs in a 0700 directory with random names", function()
        local first, close_first = auth.env("user@box", conn)
        local second, close_second = auth.env("user@box", conn)

        assert.not_equal(first.OUTPOST_ASKPASS_ASK, second.OUTPOST_ASKPASS_ASK)
        assert.equal(448, vim.uv.fs_stat(conn.askpass_dir).mode % 512)
        assert.equal(384, vim.uv.fs_stat(first.OUTPOST_ASKPASS_ASK).mode % 512)
        assert.equal(384, vim.uv.fs_stat(first.OUTPOST_ASKPASS_ANSWER).mode % 512)
        assert.equal("fifo", vim.fn.getftype(first.OUTPOST_ASKPASS_ASK))

        close_first()
        close_second()
    end)

    it("unlinks both FIFOs when the bridge closes", function()
        local env, close = auth.env("user@box", conn)

        assert.truthy(vim.uv.fs_stat(env.OUTPOST_ASKPASS_ASK))

        close()

        assert.falsy(vim.uv.fs_stat(env.OUTPOST_ASKPASS_ASK))
        assert.falsy(vim.uv.fs_stat(env.OUTPOST_ASKPASS_ANSWER))
    end)

    it("returns no bridge when it is disabled", function()
        conn.askpass = false

        assert.is_nil((auth.env("user@box", conn)))
    end)
end)

describe("askpass bridge round trip", function()
    local tmp
    local fake_dir
    local old_path
    local old_askpass
    local prompt_stub
    local conn

    local FAKE_SSH = [[#!/bin/sh
if [ -n "$FAKE_SSH_NO_ASK" ] || [ -z "$SSH_ASKPASS" ]; then
    printf 'no-askpass\n'
    exit 0
fi
out=$("$SSH_ASKPASS" "${FAKE_SSH_PROMPT:-user@box's password: }")
code=$?
if [ "$code" -ne 0 ]; then
    exit "$code"
fi
printf '%s\n' "$out"
]]

    local FAKE_SCP = [[#!/bin/sh
if [ -z "$SSH_ASKPASS" ]; then
    printf 'no-askpass\n'
    exit 0
fi
out=$("$SSH_ASKPASS" "${FAKE_SSH_PROMPT:-user@box's password: }")
code=$?
if [ "$code" -ne 0 ]; then
    exit "$code"
fi
[ "$out" = "hunter2" ] || exit 3
printf 'uploaded\n'
]]

    before_each(function()
        tmp = vim.fn.tempname()
        vim.fn.mkdir(tmp, "p")

        fake_dir = vim.fn.tempname()
        vim.fn.mkdir(fake_dir, "p")

        vim.fn.writefile(vim.split(FAKE_SSH, "\n"), fake_dir .. "/ssh")
        vim.fn.writefile(vim.split(FAKE_SCP, "\n"), fake_dir .. "/scp")
        vim.uv.fs_chmod(fake_dir .. "/ssh", 493)
        vim.uv.fs_chmod(fake_dir .. "/scp", 493)

        old_path = vim.env.PATH
        old_askpass = vim.env.SSH_ASKPASS

        vim.env.PATH = fake_dir .. ":" .. old_path
        vim.env.SSH_ASKPASS = nil
        vim.env.FAKE_SSH_PROMPT = nil
        vim.env.FAKE_SSH_NO_ASK = nil

        config.setup { askpass = true }

        prompt_stub = stub(auth, "prompt")

        conn = {
            mux = false,
            askpass = true,
            askpass_cache = tmp,
            askpass_dir = vim.fs.joinpath(tmp, "fifos"),
            askpass_timeout = 5000,
        }
    end)

    after_each(function()
        prompt_stub:revert()

        vim.env.PATH = old_path
        vim.env.SSH_ASKPASS = old_askpass
        vim.env.FAKE_SSH_PROMPT = nil
        vim.env.FAKE_SSH_NO_ASK = nil

        config.setup {}

        assert.are.same({}, vim.fn.glob(conn.askpass_dir .. "/*", false, true), "every exit path must unlink its FIFOs")

        vim.fn.delete(tmp, "rf")
        vim.fn.delete(fake_dir, "rf")
    end)

    it("carries the prompt text to the base and the answer back on stdout", function()
        local seen = {}

        prompt_stub.invokes(function(kind, text, callback)
            seen.fast = vim.in_fast_event()
            seen.kind = kind
            seen.text = text
            callback "hunter2"
        end)

        local code, out = unpack(await(transport.run, 5000, "user@box", "true", conn))

        assert.equal(0, code)
        assert.equal("hunter2", vim.trim(out))
        assert.equal("secret", seen.kind)
        assert.equal("user@box's password: ", seen.text)
        assert.falsy(seen.fast, "the prompt must run outside the reader's fast event")
    end)

    it("raises a secret with inputsecret and answers yes for a fingerprint", function()
        local seen = {}

        vim.env.FAKE_SSH_PROMPT =
            "The authenticity of host 'box' can't be established.\nED25519 key fingerprint is SHA256:abc."

        prompt_stub.invokes(function(kind, text, callback)
            seen.kind = kind
            seen.text = text
            callback "yes"
        end)

        local code, out = unpack(await(transport.run, 5000, "user@box", "true", conn))

        assert.equal(0, code)
        assert.equal("yes", vim.trim(out))
        assert.equal("confirm", seen.kind)
        assert.truthy(seen.text:find("fingerprint", 1, true))
    end)

    it("unlinks the FIFOs once the answer is read", function()
        prompt_stub.invokes(function(_, _, callback)
            callback "hunter2"
        end)

        local real_env = auth.env
        local captured
        local env_stub = stub(auth, "env").invokes(function(...)
            local env, close = real_env(...)

            captured = env

            return env, close
        end)

        await(transport.run, 5000, "user@box", "true", conn)
        env_stub:revert()

        assert.truthy(captured)
        assert.falsy(vim.uv.fs_stat(captured.OUTPOST_ASKPASS_ASK))
        assert.falsy(vim.uv.fs_stat(captured.OUTPOST_ASKPASS_ANSWER))
    end)

    it("does not leave the FIFO directory behind after a transport run", function()
        prompt_stub.invokes(function(_, _, callback)
            callback "hunter2"
        end)

        await(transport.run, 5000, "user@box", "true", conn)

        assert.are.same({}, vim.fn.glob(conn.askpass_dir .. "/*", false, true))
    end)

    it("cleans up the FIFOs when ssh never prompts", function()
        vim.env.FAKE_SSH_NO_ASK = "1"

        local code, out = unpack(await(transport.run, 5000, "user@box", "true", conn))

        assert.equal(0, code)
        assert.equal("no-askpass", vim.trim(out))
    end)

    it("attaches the bridge to scp uploads too", function()
        prompt_stub.invokes(function(_, _, callback)
            callback "hunter2"
        end)

        local ok, err = unpack(await(transport.upload, 5000, "user@box", "/tmp/local", "/tmp/remote", conn))

        assert.truthy(ok, err)
    end)

    local function run_helper(env, prompt, result)
        vim.system({ env.SSH_ASKPASS, prompt }, { env = env, text = true }, function(out)
            result.code = out.code
            result.stdout = out.stdout
        end)
    end

    local function wait_for(predicate)
        assert.truthy(vim.wait(5000, predicate), "timed out waiting for the bridge")
    end

    it("raises one prompt for two same-endpoint requests and answers both", function()
        local calls = 0
        local reply

        prompt_stub.invokes(function(_, _, callback)
            calls = calls + 1
            reply = callback
        end)

        local first, close_first = auth.env("user@box", conn)
        local second, close_second = auth.env("user@box", conn)
        local first_result, second_result = {}, {}

        run_helper(first, "user@box's password: ", first_result)
        run_helper(second, "user@box's password: ", second_result)

        wait_for(function()
            return calls == 1 and reply ~= nil
        end)

        -- let the second helper reach its prompt and join the open one
        vim.wait(200, function()
            return false
        end)

        assert.equal(1, calls, "two requests for one endpoint must share a prompt")

        reply "hunter2"

        wait_for(function()
            return first_result.code ~= nil and second_result.code ~= nil
        end)

        assert.equal(0, first_result.code)
        assert.equal("hunter2", vim.trim(first_result.stdout))
        assert.equal(0, second_result.code)
        assert.equal("hunter2", vim.trim(second_result.stdout))

        close_first()
        close_second()
    end)

    it("serialises prompts for different endpoints and drains the queue on cancel", function()
        local calls = 0
        local reply

        prompt_stub.invokes(function(_, _, callback)
            calls = calls + 1
            reply = callback
        end)

        local first, close_first = auth.env("user@one", conn)
        local second, close_second = auth.env("user@two", conn)
        local first_result, second_result = {}, {}

        run_helper(first, "password: ", first_result)
        run_helper(second, "password: ", second_result)

        wait_for(function()
            return calls == 1 and reply ~= nil
        end)

        vim.wait(200, function()
            return false
        end)

        assert.equal(1, calls, "different endpoints must not prompt at the same time")

        reply(nil)

        wait_for(function()
            return first_result.code ~= nil and second_result.code ~= nil
        end)

        assert.equal(1, first_result.code, "a cancelled helper exits nonzero")
        assert.equal(1, second_result.code, "a drained helper exits nonzero")
        assert.equal(1, calls, "a cancel must not raise further prompts")

        close_first()
        close_second()
    end)

    it("times out a prompt and makes the helper exit nonzero", function()
        conn.askpass_timeout = 100

        prompt_stub.invokes(function() end)

        local env, close = auth.env("user@box", conn)
        local result = {}

        run_helper(env, "user@box's password: ", result)

        wait_for(function()
            return result.code ~= nil
        end)

        assert.equal(1, result.code)
        assert.equal("timed out", close())
    end)

    it("refuses a prompt carrying an unknown token", function()
        local calls = 0

        prompt_stub.invokes(function(_, _, callback)
            calls = calls + 1
            callback "hunter2"
        end)

        local env, close = auth.env("user@box", conn)
        local result = {}

        vim.system({
            "sh",
            "-c",
            [[printf 'bogus\0password: \0' >"$OUTPOST_ASKPASS_ASK"; read -r A <"$OUTPOST_ASKPASS_ANSWER" && [ -n "$A" ] || exit 1; printf 'answered']],
        }, { env = env, text = true }, function(out)
            result.code = out.code
        end)

        wait_for(function()
            return result.code ~= nil
        end)

        assert.equal(1, result.code)
        assert.equal(0, calls, "an unknown token must not raise a prompt")

        close()
    end)

    it("refuses a token replayed after the first use", function()
        local calls = 0
        local reply

        prompt_stub.invokes(function(_, _, callback)
            calls = calls + 1
            reply = callback
        end)

        local env, close = auth.env("user@box", conn)
        local first, second = {}, {}

        run_helper(env, "user@box's password: ", first)

        wait_for(function()
            return calls == 1 and reply ~= nil
        end)

        vim.wait(200, function()
            return false
        end)

        reply "hunter2"

        wait_for(function()
            return first.code ~= nil
        end)

        assert.equal(0, first.code)

        run_helper(env, "user@box's password: ", second)

        wait_for(function()
            return second.code ~= nil
        end)

        assert.equal(1, second.code, "a consumed token must be refused")
        assert.equal(1, calls, "a replay must not raise a second prompt")

        close()
    end)

    it("attributes a timeout to the prompt rather than the ssh failure", function()
        conn.askpass_timeout = 100

        prompt_stub.invokes(function() end)

        local code, _, err = unpack(await(transport.run, 5000, "user@box", "true", conn))

        assert.not_equal(0, code)
        assert.truthy(err and err:find("timed out", 1, true), "the timeout must be attributed, got: " .. tostring(err))
    end)
end)

describe("default credential prompt", function()
    it("asks inputsecret for a secret and returns what was typed", function()
        local input = stub(vim.fn, "inputsecret").returns "s3cret"
        local answer

        auth.prompt("secret", "user@box's password: ", function(value)
            answer = value
        end)

        assert.equal("s3cret", answer)
        assert.equal("user@box's password: ", input.calls[1].refs[1])

        input:revert()
    end)

    it("treats an empty secret as a cancel", function()
        local input = stub(vim.fn, "inputsecret").returns ""
        local answer = "unset"

        auth.prompt("secret", "password: ", function(value)
            answer = value
        end)

        assert.is_nil(answer)

        input:revert()
    end)

    it("asks confirm for a fingerprint and returns yes, no or a cancel", function()
        local confirm_stub = stub(vim.fn, "confirm")
        local answer

        confirm_stub.returns(1)
        auth.prompt("confirm", "fingerprint?", function(value)
            answer = value
        end)
        assert.equal("yes", answer)

        confirm_stub.returns(2)
        auth.prompt("confirm", "fingerprint?", function(value)
            answer = value
        end)
        assert.equal("no", answer)

        confirm_stub.returns(0)
        auth.prompt("confirm", "fingerprint?", function(value)
            answer = value
        end)
        assert.is_nil(answer)

        confirm_stub:revert()
    end)
end)

describe("askpass bridge surface", function()
    it("opens no RPC socket anywhere in the plugin", function()
        local files = vim.fn.glob(vim.fs.joinpath(vim.fn.getcwd(), "lua/outpost/*.lua"), false, true)

        assert.truthy(#files > 0)

        for _, path in ipairs(files) do
            local text = table.concat(vim.fn.readfile(path), "\n")

            assert.falsy(text:find("serverstart", 1, true), path .. " must not open an RPC socket")
        end
    end)
end)
