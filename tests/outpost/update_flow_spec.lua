-- Integration spec: the update flow end-to-end against the docker-sshd
-- fixture (gated on the fixture being up; also needs internet — it
-- downloads the real bundle from the outpost-builds releases API).

local harness = require "outpost.harness"
local await = require "outpost.await"
local release = require "outpost.release"

describe("update flow against the fixture", function()
    it("resolves, downloads, and installs the bundle on the outpost", function()
        if not harness.pending_unless_up() then
            return
        end

        local opts = {
            conn = {
                port = harness.port(),
                key = harness.key(),
                known_hosts = harness.known_hosts(),
            },
            -- fresh cache dir per run: the miss → download → verify →
            -- install path is exercised every time, and the user's real
            -- cache is left alone
            cache_dir = vim.fn.tempname(),
        }

        -- resolve the remote: platform + home
        local remote, resolve_err = unpack(await(release.resolve_remote, nil, harness.target(), opts))

        assert.truthy(remote, resolve_err)
        assert.truthy(remote.platform:find "^linux%-")
        assert.truthy(#remote.home > 0)

        -- resolve the current release
        local tag, tag_err = unpack(await(release.latest_tag, nil))

        assert.truthy(tag, tag_err)

        -- install: download on base, checksum, transfer, extract. Idempotent
        -- against an already-installed outpost (the fixture persists across
        -- runs) — the second-install block below re-proves it.
        local ok, install_err = unpack(await(release.install, 180000, harness.target(), remote.platform, tag, opts))

        assert.truthy(ok, install_err)

        -- remote state: the version record and the installed tree
        local version = harness.remote "cat $HOME/.cache/outpost/install/version"

        assert.equal(tag, vim.trim(version.out))

        local bin = harness.remote "test -x $HOME/.cache/outpost/install/current/bin/nvim && echo bin-ok"

        assert.equal("bin-ok", vim.trim(bin.out))

        -- the module reads back the version it just recorded
        local installed = await(release.remote_version, nil, harness.target(), opts)[1]

        assert.equal(tag, installed)

        -- local cache holds the archive and its checksum
        local asset = release.asset_name(remote.platform)
        local archive_path = vim.fs.joinpath(opts.cache_dir, asset)

        assert.truthy(vim.uv.fs_stat(archive_path))
        assert.truthy(vim.uv.fs_stat(archive_path .. ".sha256"))

        local cached = vim.uv.fs_stat(archive_path)
        local ok2, install_err2 = unpack(await(release.install, 60000, harness.target(), remote.platform, tag, opts))

        assert.truthy(ok2, install_err2)

        local recached = vim.uv.fs_stat(archive_path)

        assert.equal(cached.mtime.sec, recached.mtime.sec)

        vim.fn.delete(opts.cache_dir, "rf")
    end)
end)
