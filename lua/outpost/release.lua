-- Release resolution + download pipeline.

local transport = require "outpost.transport"

local M = {}

local REPO = "juniorsundar/outpost-builds"

-- Shell-quote a value for embedding in a remote POSIX sh command.
local function shell_quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

-- Release tags come from the builds repository; refuse anything
-- that could escape the install root or confuse the remote shell.
function M.valid_tag(tag)
    return type(tag) == "string" and tag:match "^[A-Za-z0-9._-]+$" ~= nil
end

local PROBE_COMMAND = [[printf '%s\n%s\n%s\n' "$(uname -s)" "$(uname -m)" "$HOME"]]

local VERSION_COMMAND = [[cat "$HOME/.cache/outpost/install/version" 2>/dev/null || exit 1]]

-- A recorded tag is only meaningful for an install that can actually run.
local USABLE_INSTALL_COMMAND = [[
NVIM="$HOME/.cache/outpost/install/current/bin/nvim"
[ -x "$NVIM" ] || exit 1
"$NVIM" --version >/dev/null 2>&1 || exit 1
cat "$HOME/.cache/outpost/install/version" 2>/dev/null || exit 1
]]

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
TAG=%s
DEST="$INSTALL/$TAG"

case "$TAG" in *[!A-Za-z0-9._-]*) echo 'outpost-install-failed: unsafe tag'; exit 1 ;; esac

# a tree counts as installed only when its nvim actually runs: the bundle's
# musl loader is architecture-specific, and a torn extract must fail loudly
# here, never as a mysteriously dead session later
runnable() {
    [ -x "$1/bin/nvim" ] && "$1/bin/nvim" --version >/dev/null 2>&1
}

# `current` is a symlink, flipped by rename - atomic, so a running session
# keeps its tree and a new one never sees a half-extracted install. The
# replaced tag tree is left in place on purpose: a running session loads
# runtime files from it lazily, so reclaiming it is not this command's job.
flip() {
    if [ -e "$INSTALL/current" ] && [ ! -L "$INSTALL/current" ]; then
        rm -rf "$INSTALL/current" || true
    fi
    ln -sfn "$TAG" "$INSTALL/current.new"
    mv -f "$INSTALL/current.new" "$INSTALL/current"
    printf '%%s\n' "$TAG" > "$INSTALL/version"
}

# already installed, current, and runnable: nothing to do (idempotent)
if runnable "$DEST" && [ "$(cat "$INSTALL/version" 2>/dev/null)" = "$TAG" ]; then
    exit 0
fi

# this tag is already extracted and runnable: point `current` at it again
if runnable "$DEST"; then
    flip
    exit 0
fi

# extract to a per-invocation staging directory, then swap it in. Concurrent
# installs are not locked: each works in its own staging directory, the flip
# is atomic, and the worst case is duplicated work - never a half-tree in use.
STAGE="$INSTALL/.staging.$$"
trap 'rm -rf "$STAGE"' EXIT INT TERM
mkdir -p "$STAGE"
tar -xzf "$ARCHIVE" -C "$STAGE"

i=0
while ! runnable "$STAGE"; do
    i=$((i+1))
    if [ "$i" -ge 10 ]; then
        echo 'outpost-install-failed: the extracted tree is not runnable'
        exit 1
    fi
    sleep 0.3
done

rm -rf "$DEST"
mv "$STAGE" "$DEST"
flip
]],
        asset,
        shell_quote(tag)
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

    if not M.valid_tag(tag) then
        callback(false, "unsafe release tag: " .. tostring(tag))
        return
    end

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

-- The recorded release tag of a *usable* install (binary runs, tag
-- recorded), or nil when nothing usable is installed.
function M.usable_install(host, opts, callback)
    opts = opts or {}

    transport.run(host, USABLE_INSTALL_COMMAND, opts.conn, function(code, out)
        if code == 0 then
            callback(vim.trim(out))
        else
            callback(nil)
        end
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

-- Ensure the outpost has a usable portable install, idempotently: a
-- recorded install (binary + version tag) short-circuits the builds repo
-- entirely - no downloads, no releases-latest call.
function M.ensure(host, opts, callback)
    opts = opts or {}

    M.resolve_remote(host, opts, function(remote, resolve_err)
        if not remote then
            callback(nil, resolve_err)
            return
        end

        M.usable_install(host, opts, function(installed_tag)
            if installed_tag then
                callback(
                    { platform = remote.platform, home = remote.home, tag = installed_tag, installed = false },
                    nil
                )
                return
            end

            M.latest_tag(function(tag, tag_err)
                if not tag then
                    callback(nil, tag_err)
                    return
                end

                M.install(host, remote.platform, tag, opts, function(ok, install_err)
                    if not ok then
                        callback(nil, install_err)
                        return
                    end

                    callback({ platform = remote.platform, home = remote.home, tag = tag, installed = true }, nil)
                end)
            end)
        end)
    end)
end

return M
