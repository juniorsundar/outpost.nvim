-- Pinned attach client: the local-arch outpost-builds nvim of the same
-- release tag as the remote install.

local release = require "outpost.release"

local M = {}

-- The base's bundle platform from a uname pair (injectable for offline
-- specs), or nil + err when unsupported.
function M.local_platform(uname)
    uname = uname or vim.uv.os_uname()

    return release.normalize_platform(uname.sysname, uname.machine)
end

-- Where a tag's extracted client tree lives under the local client cache.
-- Platform-scoped so a cache shared across arches cannot serve the wrong
-- binary.
function M.root(platform, tag, client_dir)
    client_dir = client_dir or vim.fs.joinpath(vim.fn.stdpath "cache", "outpost", "clients")

    return vim.fs.joinpath(client_dir, platform, tag)
end

-- The injected or OUTPOST_NVIM binary override, or nil.
local function override(opts)
    local value = opts.nvim or vim.env.OUTPOST_NVIM

    if value and value ~= "" then
        return value
    end
end

-- The bundle platform to pin for: injected by specs, else the base's uname.
local function platform(opts)
    if opts.platform then
        return opts.platform
    end

    return M.local_platform()
end

-- The binary a consumer should exec: an injected path or OUTPOST_NVIM when
-- set, else the pinned client for the tag.
function M.resolve(tag, opts)
    opts = opts or {}

    local over = override(opts)

    if over then
        return over
    end

    local plat, err = platform(opts)

    if not plat then
        return nil, err
    end

    return vim.fs.joinpath(M.root(plat, tag, opts.client_dir), "bin", "nvim")
end

-- Is the binary actually runnable? A torn extract or an arch-mismatched
-- musl loader must fail here, never as a mystery at attach time.
local function runnable(bin, callback)
    if vim.fn.executable(bin) ~= 1 then
        callback(false)
        return
    end

    vim.system({ bin, "--version" }, { text = true }, function(result)
        vim.schedule(function()
            callback(result.code == 0)
        end)
    end)
end

-- Staging directories are per-invocation so concurrent extractions never
-- clobber each other. A killed or abandoned extraction leaves one behind,
-- so anything older than this grace period is reclaimed before extracting.
local STAGING_GRACE = 3600

local function staging_path(root)
    return vim.fs.joinpath(
        vim.fs.dirname(root),
        ".staging." .. vim.fs.basename(root) .. "." .. tostring(vim.uv.os_getpid())
    )
end

-- Remove stale staging directories. The grace period keeps a concurrent
-- extraction's fresh staging out of harm's way.
local function sweep_staging(root)
    local parent = vim.fs.dirname(root)
    local now = os.time()

    for name, kind in vim.fs.dir(parent) do
        if kind == "directory" and name:match "^%.staging%." then
            local path = vim.fs.joinpath(parent, name)
            local stat = vim.uv.fs_stat(path)

            if stat and now - stat.mtime.sec > STAGING_GRACE then
                vim.fn.delete(path, "rf")
            end
        end
    end
end

-- Extract a verified archive into the tag's tree: staging, runnable check,
-- atomic rename. A failed extract leaves nothing behind.
function M.extract(archive, root, callback)
    local staging = staging_path(root)

    vim.fn.mkdir(vim.fs.dirname(root), "p")
    sweep_staging(root)
    vim.fn.delete(staging, "rf")
    vim.fn.mkdir(staging, "p")

    vim.system({ "tar", "-xzf", archive, "-C", staging }, { text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                vim.fn.delete(staging, "rf")
                callback(false, result.stderr or "client extraction failed")
                return
            end

            runnable(vim.fs.joinpath(staging, "bin", "nvim"), function(ok)
                if not ok then
                    vim.fn.delete(staging, "rf")
                    callback(false, "the extracted client is not runnable")
                    return
                end

                vim.fn.delete(root, "rf")

                local renamed, rename_err = vim.uv.fs_rename(staging, root)

                if not renamed then
                    vim.fn.delete(staging, "rf")
                    callback(false, "could not install the pinned client: " .. tostring(rename_err))
                    return
                end

                callback(true, nil)
            end)
        end)
    end)
end

-- Ensure the extracted pinned client for a tag exists, consulting the
-- release pipeline only on a cache miss. callback(path, err).
function M.ensure(tag, opts, callback)
    opts = opts or {}

    local over = override(opts)

    if over then
        callback(over, nil)
        return
    end

    local plat, err = platform(opts)

    if not plat then
        callback(nil, err)
        return
    end

    local root = M.root(plat, tag, opts.client_dir)
    local bin = vim.fs.joinpath(root, "bin", "nvim")

    runnable(bin, function(ok)
        if ok then
            callback(bin, nil)
            return
        end

        release.ensure_archive(plat, tag, opts.cache_dir, function(archive, archive_err)
            if not archive then
                callback(nil, archive_err)
                return
            end

            M.extract(archive, root, function(extracted, extract_err)
                if not extracted then
                    callback(nil, extract_err)
                    return
                end

                callback(bin, nil)
            end)
        end)
    end)
end

return M
