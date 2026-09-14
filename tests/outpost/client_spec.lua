-- Unit spec for the pinned attach client's resolution helpers (offline by
-- construction).

local client = require "outpost.client"

local await = require "outpost.await"

local function write_file(path, content, mode)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile(vim.split(content, "\n"), path)
    vim.uv.fs_chmod(path, mode)
end

-- Build a real tarball from injected entries ({ ["bin/nvim"] = { content, mode } }).
local function make_archive(dir, entries)
    local src = vim.fs.joinpath(dir, "src")

    for rel, spec in pairs(entries) do
        write_file(vim.fs.joinpath(src, rel), spec.content, spec.mode)
    end

    local archive = vim.fs.joinpath(dir, "client.tar.gz")
    local result = vim.system({ "tar", "-czf", archive, "-C", src, "." }):wait()

    assert.equal(0, result.code)

    return archive
end

-- Staging directories left in the tag's parent by an extraction.
local function staging_dirs(root)
    local parent = vim.fs.dirname(root)
    local found = {}

    if not vim.uv.fs_stat(parent) then
        return found
    end

    for name, kind in vim.fs.dir(parent) do
        if kind == "directory" and name:match "^%.staging%." then
            table.insert(found, vim.fs.joinpath(parent, name))
        end
    end

    return found
end

describe("attach client platform", function()
    it("maps the base's uname pair to a bundle platform", function()
        assert.equal("linux-x86_64", client.local_platform { sysname = "Linux", machine = "x86_64" })
        assert.equal("linux-aarch64", client.local_platform { sysname = "Linux", machine = "aarch64" })
    end)

    it("refuses an unsupported base with a clear error", function()
        local platform, err = client.local_platform { sysname = "Darwin", machine = "arm64" }

        assert.is_nil(platform)
        assert.equal("unsupported operating system: Darwin", err)
    end)
end)

describe("pinned client path", function()
    it("keys the extracted client by platform and tag", function()
        assert.equal("/cache/clients/linux-x86_64/v0.12.5", client.root("linux-x86_64", "v0.12.5", "/cache/clients"))
    end)

    it("resolves the binary inside the tag's extracted tree", function()
        assert.equal(
            "/cache/clients/linux-x86_64/v0.12.5/bin/nvim",
            client.resolve("v0.12.5", { platform = "linux-x86_64", client_dir = "/cache/clients" })
        )
    end)

    it("resolves a different path when the recorded tag changes", function()
        local opts = { platform = "linux-x86_64", client_dir = "/cache/clients" }

        assert.truthy(client.resolve("v0.12.5", opts) ~= client.resolve("v0.12.6", opts))
    end)
end)

describe("attach client override", function()
    after_each(function()
        vim.env.OUTPOST_NVIM = nil
    end)

    it("lets an injected path replace the pinned client", function()
        assert.equal("/opt/nvim/bin/nvim", client.resolve("v0.12.5", { nvim = "/opt/nvim/bin/nvim" }))
    end)

    it("honors the OUTPOST_NVIM environment variable", function()
        vim.env.OUTPOST_NVIM = "/env/nvim"

        assert.equal("/env/nvim", client.resolve("v0.12.5", {}))
    end)

    it("prefers the injected path over the environment", function()
        vim.env.OUTPOST_NVIM = "/env/nvim"

        assert.equal("/injected/nvim", client.resolve("v0.12.5", { nvim = "/injected/nvim" }))
    end)

    it("ignores an empty override", function()
        vim.env.OUTPOST_NVIM = ""

        assert.equal(
            "/cache/clients/linux-x86_64/v0.12.5/bin/nvim",
            client.resolve("v0.12.5", { platform = "linux-x86_64", client_dir = "/cache/clients" })
        )
    end)
end)

describe("pinned client extraction", function()
    local tmp
    local root

    before_each(function()
        tmp = vim.fn.tempname()
        vim.fn.mkdir(tmp, "p")
        root = vim.fs.joinpath(tmp, "clients", "linux-x86_64", "v0.12.5")
    end)

    after_each(function()
        vim.fn.delete(tmp, "rf")
    end)

    it("extracts a verified archive into the tag's tree", function()
        local archive = make_archive(tmp, {
            ["bin/nvim"] = { content = "#!/bin/sh\necho NVIM v0.0.0", mode = 493 },
        })

        local ok, err = unpack(await(client.extract, 30000, archive, root))

        assert.truthy(ok, err)
        assert.equal(1, vim.fn.executable(vim.fs.joinpath(root, "bin", "nvim")))
        assert.equal("NVIM v0.0.0\n", vim.fn.system { vim.fs.joinpath(root, "bin", "nvim"), "--version" })
    end)

    it("errors on a corrupt archive and extracts nothing", function()
        local archive = vim.fs.joinpath(tmp, "corrupt.tar.gz")

        vim.fn.writefile({ "not a tarball" }, archive)

        local ok, err = unpack(await(client.extract, 30000, archive, root))

        assert.falsy(ok)
        assert.truthy(err)
        assert.falsy(vim.uv.fs_stat(root))
        assert.equal(0, #staging_dirs(root))
    end)

    it("refuses a tree whose nvim does not run and leaves nothing behind", function()
        local archive = make_archive(tmp, {
            ["bin/nvim"] = { content = "not runnable", mode = 420 },
        })

        local ok, err = unpack(await(client.extract, 30000, archive, root))

        assert.falsy(ok)
        assert.truthy(err)
        assert.falsy(vim.uv.fs_stat(root))
        assert.equal(0, #staging_dirs(root))
    end)

    it("reclaims a staging directory left behind by a killed extraction", function()
        local archive = make_archive(tmp, {
            ["bin/nvim"] = { content = "#!/bin/sh\necho NVIM v0.0.0", mode = 493 },
        })

        local stale = vim.fs.joinpath(vim.fs.dirname(root), ".staging.v0.12.5.999999")
        local old = os.time() - 7200

        vim.fn.mkdir(stale, "p")
        vim.uv.fs_utime(stale, old, old)

        local ok, err = unpack(await(client.extract, 30000, archive, root))

        assert.truthy(ok, err)
        assert.falsy(vim.uv.fs_stat(stale), "a stale staging dir must be reclaimed")
    end)

    it("leaves a concurrent extraction's fresh staging directory alone", function()
        local archive = make_archive(tmp, {
            ["bin/nvim"] = { content = "#!/bin/sh\necho NVIM v0.0.0", mode = 493 },
        })

        local fresh = vim.fs.joinpath(vim.fs.dirname(root), ".staging.v0.12.5.999998")

        vim.fn.mkdir(fresh, "p")

        local ok, err = unpack(await(client.extract, 30000, archive, root))

        assert.truthy(ok, err)
        assert.truthy(vim.uv.fs_stat(fresh), "a fresh staging dir may belong to another extraction")
    end)
end)

describe("pinned client ensure", function()
    local tmp
    local client_dir
    local cache_dir

    local platform = "linux-x86_64"
    local tag = "v0.12.5"

    before_each(function()
        tmp = vim.fn.tempname()
        vim.fn.mkdir(tmp, "p")
        client_dir = vim.fs.joinpath(tmp, "clients")
        cache_dir = vim.fs.joinpath(tmp, "downloads")
    end)

    after_each(function()
        vim.fn.delete(tmp, "rf")
        vim.env.OUTPOST_NVIM = nil
    end)

    local function seed_pinned_tree()
        local bin = vim.fs.joinpath(client.root(platform, tag, client_dir), "bin", "nvim")

        write_file(bin, "#!/bin/sh\necho NVIM v0.0.0", 493)

        return bin
    end

    it("reuses an already-extracted client without touching the download cache", function()
        local bin = seed_pinned_tree()
        local path, err = unpack(
            await(client.ensure, 30000, tag, { platform = platform, client_dir = client_dir, cache_dir = cache_dir })
        )

        assert.equal(bin, path, err)
        assert.falsy(vim.uv.fs_stat(cache_dir), "a cache hit must not contact the release pipeline")
    end)

    it("lets OUTPOST_NVIM replace the pinned client without extracting", function()
        vim.env.OUTPOST_NVIM = "/env/nvim"

        local path, err = unpack(
            await(client.ensure, 30000, tag, { platform = platform, client_dir = client_dir, cache_dir = cache_dir })
        )

        assert.equal("/env/nvim", path, err)
        assert.falsy(vim.uv.fs_stat(client_dir))
        assert.falsy(vim.uv.fs_stat(cache_dir))
    end)
end)
