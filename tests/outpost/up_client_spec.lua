-- Integration spec: `up` pins the local attach client to the remote
-- install's recorded release tag. Gated on the fixture being up; the first
-- pin downloads the real bundle, so it also needs internet.

local up = require "outpost.up"
local client = require "outpost.client"

local harness = require "outpost.harness"
local await = require "outpost.await"

describe("up pinned attach client", function()
    local opts
    local registry_dir
    local cache_dir
    local client_dir

    -- set while a spec has rewritten the recorded tag, so it can be restored
    local real_tag
    local fake_root

    before_each(function()
        if not harness.pending_unless_up() then
            return
        end

        registry_dir = vim.fn.tempname()
        vim.fn.mkdir(registry_dir, "p")

        -- one download cache and one pinned-client cache for the whole spec
        cache_dir = cache_dir or vim.fn.tempname()
        client_dir = client_dir or vim.fn.tempname()

        opts = {
            conn = {
                port = harness.port(),
                key = harness.key(),
                known_hosts = harness.known_hosts(),
            },
            registry_dir = registry_dir,
            cache_dir = cache_dir,
            client_dir = client_dir,
        }

        harness.remote "mkdir -p $HOME/proj"
    end)

    after_each(function()
        if registry_dir then
            vim.fn.delete(registry_dir, "rf")
        end

        -- never leak a simulated tag change into the next spec
        if real_tag then
            harness.remote(("printf '%%s' '%s' > $HOME/.cache/outpost/install/version"):format(real_tag))
            real_tag = nil
        end

        if fake_root then
            vim.fn.delete(fake_root, "rf")
            fake_root = nil
        end
    end)

    local function remote_tag()
        return vim.trim(harness.remote("cat $HOME/.cache/outpost/install/version").out)
    end

    it("pins the local client to the remote install's recorded tag", function()
        if not harness.pending_unless_up() then
            return
        end

        -- a fresh outpost: nothing installed, no pinned client
        harness.remote "rm -rf $HOME/.cache/outpost"

        local result, err = unpack(await(up.run, 180000, "outpost@127.0.0.1:~/proj", opts))

        assert.truthy(result, err)
        assert.equal(remote_tag(), result.tag)

        -- the pin is the local-arch client for that tag, under the injected cache
        local platform = assert(client.local_platform())

        assert.truthy(result.client:find(client_dir, 1, true))
        assert.truthy(result.client:find(platform, 1, true))
        assert.truthy(result.client:find(result.tag, 1, true))

        -- and it actually runs
        assert.equal(1, vim.fn.executable(result.client), "pinned client must be executable")

        local version = vim.system({ result.client, "--version" }, { text = true }):wait()

        assert.equal(0, version.code)
    end)

    it("re-running up with an unchanged tag downloads nothing", function()
        if not harness.pending_unless_up() then
            return
        end

        local first = (await(up.run, 180000, "outpost@127.0.0.1:~/proj", opts))[1]

        assert.truthy(first)

        local mtime = vim.uv.fs_stat(first.client).mtime.sec

        -- a fresh, empty download cache: a re-download would have to create it
        local fresh = vim.fn.tempname()
        local second = (await(up.run, 60000, "outpost@127.0.0.1:~/proj", {
            conn = opts.conn,
            registry_dir = registry_dir,
            cache_dir = fresh,
            client_dir = client_dir,
        }))[1]

        assert.truthy(second)
        assert.equal(first.client, second.client)
        assert.equal(first.tag, second.tag)

        -- the pinned tree was reused: same mtime, no fresh download cache
        assert.equal(mtime, vim.uv.fs_stat(second.client).mtime.sec)
        assert.falsy(vim.uv.fs_stat(fresh), "an unchanged tag must not contact the release pipeline")
    end)

    it("refreshes the pin when the recorded tag changes", function()
        if not harness.pending_unless_up() then
            return
        end

        local first = (await(up.run, 180000, "outpost@127.0.0.1:~/proj", opts))[1]

        assert.truthy(first)

        real_tag = remote_tag()

        -- simulate `:Outpost update` recording a newer tag. There is only one
        -- published release, so seed the tree that tag would resolve to
        -- instead of downloading a second bundle.
        local fake = real_tag .. "-pinned-test"

        local tag_root = vim.fs.dirname(vim.fs.dirname(first.client))

        fake_root = vim.fs.joinpath(vim.fs.dirname(tag_root), fake)
        vim.fn.system { "cp", "-a", tag_root, fake_root }

        assert.equal(0, vim.v.shell_error, "could not seed the simulated client tree")

        -- the remote records the new tag; the running tree is untouched, so
        -- the install stays usable
        harness.remote(("printf '%%s' '%s' > $HOME/.cache/outpost/install/version"):format(fake))

        local second = (await(up.run, 120000, "outpost@127.0.0.1:~/proj", opts))[1]

        assert.truthy(second)
        assert.equal(fake, second.tag)
        assert.truthy(second.client ~= first.client)
        assert.equal(vim.fs.joinpath(fake_root, "bin", "nvim"), second.client)
        assert.equal(1, vim.fn.executable(second.client))
    end)
end)
