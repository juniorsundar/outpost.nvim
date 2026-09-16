local release = require "outpost.release"
local fixture = require "outpost.release_fixture"
local await = require "outpost.await"

describe("persistent release fixture", function()
    local root, old_cache, latest_tag, ensure_archive, asset_url
    local resolutions, downloads
    local tag = "v0.12.5"
    local platform = assert(require("outpost.client").local_platform())
    local asset = release.asset_name(platform)

    before_each(function()
        root = vim.fn.tempname() .. " cache #1"
        old_cache = vim.env.OUTPOST_TEST_CACHE
        vim.env.OUTPOST_TEST_CACHE = root
        latest_tag, ensure_archive, asset_url = release.latest_tag, release.ensure_archive, release.asset_url
        resolutions, downloads = 0, 0
        release.latest_tag = function(callback)
            resolutions = resolutions + 1
            callback(tag)
        end
        release.ensure_archive = function(_, _, dir, callback)
            downloads = downloads + 1
            vim.fn.mkdir(dir, "p")
            vim.fn.writefile({ "fixture bytes" }, dir .. "/" .. asset)
            local sum = vim.system({ "sha256sum", asset }, { cwd = dir, text = true }):wait()
            assert.equal(0, sum.code)
            vim.fn.writefile({ vim.trim(sum.stdout) }, dir .. "/" .. asset .. ".sha256")
            callback(dir .. "/" .. asset)
        end
    end)

    after_each(function()
        release.latest_tag, release.ensure_archive, release.asset_url = latest_tag, ensure_archive, asset_url
        vim.env.OUTPOST_TEST_CACHE = old_cache
        vim.fn.delete(root, "rf")
    end)

    it("downloads once across preparations; refresh is explicit", function()
        fixture.prepare()
        fixture.prepare()
        assert.equal(1, resolutions)
        assert.equal(1, downloads)
        fixture.prepare(true)
        assert.equal(2, resolutions)
        assert.equal(2, downloads)
    end)

    it("does not publish a pin when downloading fails", function()
        release.ensure_archive = function(_, _, _, callback)
            callback(nil, "download failed")
        end
        assert.has_error(function()
            fixture.prepare()
        end, "download failed")
        assert.equal(0, vim.fn.filereadable(root .. "/tag"))
    end)

    it("rejects a corrupted warm fixture without fetching", function()
        fixture.prepare()
        vim.fn.writefile({ "corrupt" }, root .. "/releases/" .. tag .. "/" .. asset)
        assert.has_error(function()
            fixture.prepare()
        end, "release fixture checksum failed; run make test-fixture-refresh")
        assert.equal(1, downloads)
        assert.equal(1, resolutions)
    end)

    it("drives real cold download and checksum paths using local URLs, not GitHub", function()
        fixture.prepare()
        fixture.use()
        release.ensure_archive = ensure_archive
        assert.equal(tag, await(release.latest_tag, nil)[1])
        assert.matches("^file://", release.asset_url(tag, asset))

        local dest = root .. "/cold-download"
        local path, err = unpack(await(release.ensure_archive, nil, platform, tag, dest))
        assert.equal(dest .. "/" .. asset, path, err)
        assert.same({ "fixture bytes" }, vim.fn.readfile(path))
        assert.has_error(function()
            release.asset_url("unexpected-tag", asset)
        end, "release is not in the prepared test fixture: unexpected-tag")

        -- No fallback to GitHub even when the cached source is damaged.
        vim.fn.writefile({ "corrupt" }, root .. "/releases/" .. tag .. "/" .. asset)
        vim.fn.delete(dest, "rf")
        local bad, checksum_err = unpack(await(release.ensure_archive, nil, platform, tag, dest))
        assert.is_nil(bad)
        assert.truthy(checksum_err)
    end)
end)
