-- Release resolution + download pipeline.

local transport = require "outpost.transport"

local M = {}

local REPO = "juniorsundar/outpost-builds"

local PROBE_COMMAND = [[printf '%s\n%s\n%s\n' "$(uname -s)" "$(uname -m)" "$HOME"]]

local VERSION_COMMAND = [[cat "$HOME/.cache/outpost/install/version" 2>/dev/null || exit 1]]

function M.normalize_platform(os_name, arch)
    if os_name ~= "Linux" then
        return nil, "unsupported operating system: " .. os_name
    end

    local arch_map = {
        x86_64 = "x86_64",
        amd64 = "x86_64",

        aarch64 = "aarch64",
        arm64 = "aarch64",
    }

    local normalized_arch = arch_map[arch]

    if not normalized_arch then
        return nil, "unsupported architecture: " .. arch
    end

    return "linux-" .. normalized_arch
end

function M.asset_name(platform)
    return "nvim-portable-" .. platform .. ".tar.gz"
end

function M.asset_url(tag, asset)
    return string.format("https://github.com/%s/releases/download/%s/%s", REPO, tag, asset)
end

function M.latest_tag(callback)
    vim.system({
        "curl",
        "-fsSL",
        "https://api.github.com/repos/" .. REPO .. "/releases/latest",
    }, { text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                callback(nil, result.stderr or "failed to resolve latest release")
                return
            end

            local ok, decoded = pcall(vim.json.decode, result.stdout)

            if not ok or type(decoded) ~= "table" or not decoded.tag_name then
                callback(nil, "could not parse latest release response")
                return
            end

            callback(decoded.tag_name, nil)
        end)
    end)
end

local function download(url, path, callback)
    vim.fn.mkdir(vim.fs.dirname(path), "p")

    vim.system({
        "curl",
        "-fL",
        "--output",
        path,
        url,
    }, { text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                callback(nil, result.stderr or "download failed")
                return
            end

            callback(path, nil)
        end)
    end)
end

local function verify_sha256(archive_path, checksum_path, callback)
    vim.system({
        "sha256sum",
        "-c",
        checksum_path,
    }, {
        text = true,
        cwd = vim.fs.dirname(archive_path),
    }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                callback(false, result.stderr or result.stdout or "checksum verification failed")
                return
            end

            callback(true, result.stdout)
        end)
    end)
end

-- Resolve a cached archive for the platform/tag, downloading only when the
-- cached copy is missing or fails checksum verification. Multiple remote
-- hosts therefore share a single download.
local function ensure_archive(platform, tag, cache_dir, callback)
    local asset = M.asset_name(platform)
    cache_dir = cache_dir or vim.fs.joinpath(vim.fn.stdpath "cache", "outpost", "downloads")

    local archive_path = vim.fs.joinpath(cache_dir, asset)
    local checksum_path = vim.fs.joinpath(cache_dir, asset .. ".sha256")

    local function get_archive(cb)
        download(M.asset_url(tag, asset), archive_path, function(_, err)
            if err then
                cb(nil, err)
                return
            end

            verify_sha256(archive_path, checksum_path, function(ok, result)
                if not ok then
                    cb(nil, result)
                    return
                end

                cb(archive_path, nil)
            end)
        end)
    end

    download(M.asset_url(tag, asset .. ".sha256"), checksum_path, function(_, err)
        if err then
            callback(nil, err)
            return
        end

        if not vim.uv.fs_stat(archive_path) then
            get_archive(callback)
            return
        end

        verify_sha256(archive_path, checksum_path, function(ok)
            if ok then
                callback(archive_path, nil)
                return
            end

            get_archive(callback)
        end)
    end)
end

local function install_remote(host, asset, tag, conn, callback)
    local command = string.format(
        [[
set -eu
INSTALL="$HOME/.cache/outpost/install"
ARCHIVE="$HOME/.cache/outpost/downloads/%s"

rm -rf "$INSTALL/current"
mkdir -p "$INSTALL/current" "$HOME/.cache/outpost/downloads"
tar -xzf "$ARCHIVE" -C "$INSTALL/current"
printf '%%s\n' '%s' > "$INSTALL/version"
]],
        asset,
        tag
    )

    transport.run(host, command, conn, function(code, _, err)
        if code ~= 0 then
            callback(false, err or "remote install failed")
            return
        end

        callback(true, nil)
    end)
end

-- Transfer the archive onto the outpost and install it: extract the bundle,
-- record the installed release tag.
function M.install(host, platform, tag, opts, callback)
    opts = opts or {}

    ensure_archive(platform, tag, opts.cache_dir, function(archive, err)
        if not archive then
            callback(false, err)
            return
        end

        transport.run(host, "mkdir -p ~/.cache/outpost/downloads", opts.conn, function(code, _, err)
            if code ~= 0 then
                callback(false, err or "remote mkdir failed")
                return
            end

            local remote_path = "~/.cache/outpost/downloads/" .. vim.fs.basename(archive)

            transport.upload(host, archive, remote_path, opts.conn, function(ok, upload_err)
                if not ok then
                    callback(false, upload_err)
                    return
                end

                install_remote(host, vim.fs.basename(archive), tag, opts.conn, function(installed, install_err)
                    if not installed then
                        callback(false, install_err)
                        return
                    end

                    callback(true, nil)
                end)
            end)
        end)
    end)
end

-- Probe the outpost: uname pair for platform normalization and the
-- account's home directory.
function M.resolve_remote(host, opts, callback)
    opts = opts or {}

    transport.run(host, PROBE_COMMAND, opts.conn, function(code, out, err)
        if code ~= 0 then
            callback(nil, err or "ssh probe failed")
            return
        end

        local lines = vim.split(vim.trim(out), "\n")
        local remote_home = lines[3]

        local platform, err = M.normalize_platform(lines[1], lines[2])

        if not platform then
            callback(nil, err)
            return
        end

        callback({
            platform = platform,
            home = remote_home,
        }, nil)
    end)
end

-- The release tag recorded on the outpost, or nil when nothing is
-- installed (the recorded install short-circuits all downloads).
function M.remote_version(host, opts, callback)
    opts = opts or {}

    transport.run(host, VERSION_COMMAND, opts.conn, function(code, out)
        if code == 0 then
            callback(vim.trim(out))
        else
            callback(nil)
        end
    end)
end

return M
