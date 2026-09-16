-- Integration spec: the `up` identity ladder against the docker-sshd
-- fixture. Gated on the fixture being up (pending, not failing, without
-- docker). Drives `up.resolve` - the identity stage of the ladder (typed
-- target -> endpoint -> one remote round trip -> session id); the full `up`
-- flow on top of it (provisioning, session start, registry, notifications)
-- is covered by up_session_spec.lua. Asserts observable results only.

local target = require "outpost.target"
local up = require "outpost.up"

local harness = require "outpost.harness"
local await = require "outpost.await"

describe("up identity ladder", function()
    local opts

    before_each(function()
        if not harness.pending_unless_up() then
            return
        end

        local ssh_config = vim.fn.tempname() .. ".config"

        vim.fn.writefile({
            "Host outposttest",
            "  HostName 127.0.0.1",
            "  Port 2222",
        }, ssh_config)

        opts = {
            conn = {
                port = harness.port(),
                key = harness.key(),
                known_hosts = harness.known_hosts(),
            },
            ssh_config = ssh_config,
        }

        -- every spec is self-contained: its own project dir and symlink
        harness.remote "mkdir -p $HOME/proj"
        harness.remote "ln -sfn $HOME/proj $HOME/projlink"
    end)

    it("reports the six-character session id for the resolved target", function()
        if not harness.pending_unless_up() then
            return
        end

        local result, err = unpack(await(up.resolve, 30000, target.parse "outpost@127.0.0.1:~/proj", opts))

        assert.truthy(result, err)
        assert.matches("^%x%x%x%x%x%x$", result.session_id)
    end)

    it("resolves an ssh-config alias and its literal spelling to the same session id", function()
        if not harness.pending_unless_up() then
            return
        end

        local alias_result, alias_err =
            unpack(await(up.resolve, 30000, target.parse "outpost@outposttest:~/proj", opts))
        local literal_result, literal_err =
            unpack(await(up.resolve, 30000, target.parse "outpost@127.0.0.1:~/proj", opts))

        assert.truthy(alias_result, alias_err)
        assert.truthy(literal_result, literal_err)
        assert.equal(alias_result.session_id, literal_result.session_id)
    end)

    it("mints the instance id once on the outpost and reuses it", function()
        if not harness.pending_unless_up() then
            return
        end

        -- fresh identity: drop the instance id and run dir; the portable
        -- install (from update_flow_spec) is left alone
        harness.remote "rm -rf $HOME/.cache/outpost/instance-id"

        local first, err = unpack(await(up.resolve, 30000, target.parse "outpost@127.0.0.1:~/proj", opts))

        assert.truthy(first, err)

        local minted = vim.trim(harness.remote("cat $HOME/.cache/outpost/instance-id").out)

        assert.equal(first.instance_id, minted)

        local second, second_err = unpack(await(up.resolve, 30000, target.parse "outpost@127.0.0.1:~/proj", opts))

        assert.truthy(second, second_err)
        assert.equal(minted, second.instance_id)
        assert.equal(first.session_id, second.session_id)
    end)

    it("converges trailing-slash and symlinked spellings on one session id", function()
        if not harness.pending_unless_up() then
            return
        end

        local plain, err = unpack(await(up.resolve, 30000, target.parse "outpost@127.0.0.1:~/proj", opts))

        assert.truthy(plain, err)

        local trailing, trailing_err = unpack(await(up.resolve, 30000, target.parse "outpost@127.0.0.1:~/proj/", opts))

        assert.truthy(trailing, trailing_err)

        local symlinked, symlink_err =
            unpack(await(up.resolve, 30000, target.parse "outpost@127.0.0.1:~/projlink", opts))

        assert.truthy(symlinked, symlink_err)

        assert.equal("/home/outpost/proj", plain.canonical_path)
        assert.equal(plain.session_id, trailing.session_id)
        assert.equal(plain.session_id, symlinked.session_id)
    end)

    it("errors clearly on a missing project directory and creates nothing", function()
        if not harness.pending_unless_up() then
            return
        end

        -- fresh identity state: the failing resolve must not recreate anything
        harness.remote "rm -rf $HOME/.cache/outpost/instance-id $HOME/.cache/outpost/run"

        local result, err = unpack(await(up.resolve, 30000, target.parse "outpost@127.0.0.1:~/code/nope", opts))

        assert.is_nil(result)
        assert.matches("no project directory", err)

        -- nothing created on the remote: no identity minted, no run dir
        assert.equal(1, harness.remote("test -e $HOME/.cache/outpost/instance-id").code)
        assert.equal(1, harness.remote("test -e $HOME/.cache/outpost/run").code)
    end)
end)
