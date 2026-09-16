-- The published bundle is fetched once; normal integration specs download
-- from this local mirror while keeping the real checksum/install pipeline.
local release = require "outpost.release"
local await = require "outpost.await"

local M = {}

function M.root()
    return vim.fs.normalize(vim.env.OUTPOST_TEST_CACHE or vim.fn.expand "~/.cache/outpost-tests")
end

local function pin()
    local path = M.root() .. "/tag"
    if vim.fn.filereadable(path) == 0 then
        return nil
    end
    local tag = vim.fn.readfile(path)[1]
    assert(release.valid_tag(tag), "invalid test fixture tag; run make test-fixture-refresh")
    return tag
end

function M.prepare(refresh)
    local tag = not refresh and pin() or nil
    local platform = assert(require("outpost.client").local_platform())
    if not tag then
        local err
        tag, err = unpack(await(release.latest_tag, 30000))
        if not tag then
            error(err, 0)
        end
        assert(release.valid_tag(tag), "invalid release tag")
        local archive, download_err =
            unpack(await(release.ensure_archive, 180000, platform, tag, M.root() .. "/releases/" .. tag))
        if not archive then
            error(download_err, 0)
        end
    end

    local dir = M.root() .. "/releases/" .. tag
    local verified = vim.system({ "sha256sum", "-c", release.asset_name(platform) .. ".sha256" }, {
        cwd = dir,
        text = true,
    }):wait()
    if verified.code ~= 0 then
        error("release fixture checksum failed; run make test-fixture-refresh", 0)
    end

    -- Publish only after verification; failed refreshes leave the old pin.
    vim.fn.writefile({ tag }, M.root() .. "/tag.new")
    assert(vim.uv.fs_rename(M.root() .. "/tag.new", M.root() .. "/tag"))
    return tag
end

function M.use()
    local tag = assert(pin(), "release fixture missing; run make test-fixture")
    local root = M.root() .. "/releases/" .. tag
    release.latest_tag = function(callback)
        vim.schedule(function()
            callback(tag)
        end)
    end
    release.asset_url = function(requested_tag, asset)
        if requested_tag ~= tag then
            error("release is not in the prepared test fixture: " .. tostring(requested_tag), 0)
        end
        assert(
            asset:match "^nvim%-portable%-linux%-[%w_]+%.tar%.gz$"
                or asset:match "^nvim%-portable%-linux%-[%w_]+%.tar%.gz%.sha256$"
        )
        return vim.uri_from_fname(root .. "/" .. asset)
    end
end

return M
