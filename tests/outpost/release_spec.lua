-- Unit spec for the pure helpers of the release pipeline (offline by
-- construction).

local helpers = require "outpost.view_helpers"
local release = require "outpost.release"

describe("platform normalization", function()
    it("maps linux uname pairs to bundle platforms", function()
        assert.equal("linux-x86_64", release.normalize_platform("Linux", "x86_64"))
        assert.equal("linux-aarch64", release.normalize_platform("Linux", "aarch64"))
    end)

    it("accepts common arch aliases", function()
        assert.equal("linux-x86_64", release.normalize_platform("Linux", "amd64"))
        assert.equal("linux-aarch64", release.normalize_platform("Linux", "arm64"))
    end)

    it("refuses unsupported operating systems with a clear error", function()
        local platform, err = release.normalize_platform("Darwin", "x86_64")

        assert.is_nil(platform)
        assert.equal("unsupported operating system: Darwin", err)
    end)

    it("refuses unsupported architectures with a clear error", function()
        local platform, err = release.normalize_platform("Linux", "mips")

        assert.is_nil(platform)
        assert.equal("unsupported architecture: mips", err)
    end)
end)

describe("asset construction", function()
    it("names the portable bundle asset for the platform", function()
        assert.equal("nvim-portable-linux-x86_64.tar.gz", release.asset_name "linux-x86_64")
        assert.equal("nvim-portable-linux-aarch64.tar.gz", release.asset_name "linux-aarch64")
    end)

    it("builds the release download url from tag and asset", function()
        assert.equal(
            "https://github.com/juniorsundar/outpost-builds/releases/download/v9.9.9-test/nvim-portable-linux-x86_64.tar.gz",
            release.asset_url("v9.9.9-test", "nvim-portable-linux-x86_64.tar.gz")
        )
    end)
end)

describe("release tag validation", function()
    it("accepts the tag shapes the builds repository publishes", function()
        assert.truthy(release.valid_tag "v0.12.5")
        assert.truthy(release.valid_tag "v0.10.0-nightly-20250101")
    end)

    it("refuses tags that could escape the install root or break the shell", function()
        assert.falsy(release.valid_tag "../../etc")
        assert.falsy(release.valid_tag "v1; rm -rf $HOME")
        assert.falsy(release.valid_tag "v1'")
        assert.falsy(release.valid_tag "v1/x")
        assert.falsy(release.valid_tag "")
        assert.falsy(release.valid_tag(nil))
    end)
end)

local await = require "outpost.await"
local transport = require "outpost.transport"

local stub = require "luassert.stub"

describe("release download stream seam", function()
    it("streams curl's stderr meter while the body lands", function()
        local source = vim.fn.tempname()
        vim.fn.writefile({ "bundle bytes" }, source)

        local dest = vim.fn.tempname()
        local chunks = {}
        local result, err

        release.download("file://" .. source, dest, function(path, download_err)
            result, err = path, download_err
        end, function(chunk, pipe)
            table.insert(chunks, { chunk = chunk, source = pipe })
        end)

        assert.truthy(
            vim.wait(10000, function()
                return (result or err) ~= nil
            end),
            "the download never finished"
        )

        assert.equal(dest, result, err)

        local meter = {}

        for _, entry in ipairs(chunks) do
            assert.equal("stderr", entry.source)
            table.insert(meter, entry.chunk)
        end

        assert.truthy(#meter > 0, "the meter never streamed")
        assert.truthy(table.concat(meter):find("Total", 1, true))

        vim.fn.delete(source)
        vim.fn.delete(dest)
    end)
end)

describe("release archive streaming", function()
    -- A stubbed download that lays down a real archive and a matching
    -- checksum, so the real verify path runs over both.
    local function stub_download(calls)
        local s = stub(release, "download")

        s.invokes(function(url, path, callback, on_chunk)
            table.insert(calls, { url = url, path = path, on_chunk = on_chunk })
            vim.fn.mkdir(vim.fs.dirname(path), "p")

            if path:find "%.sha256$" then
                -- sha256sum -c matches the entry against the archive's own basename
                vim.fn.writefile({ vim.fn.sha256 "bundle" .. "  nvim-portable-linux-x86_64.tar.gz" }, path, "b")
                callback(path, nil)
                return
            end

            vim.fn.writefile({ "bundle" }, path, "b")
            callback(path, nil)
        end)

        return s
    end

    it("threads the stream handler into the checksum and the archive download", function()
        local calls = {}
        local s = stub_download(calls)
        local cache = vim.fn.tempname()
        local handler = function() end
        local archive, err

        release.ensure_archive("linux-x86_64", "v0.2.0", cache, function(path, ensure_err)
            archive, err = path, ensure_err
        end, handler)

        assert.truthy(
            vim.wait(10000, function()
                return (archive or err) ~= nil
            end),
            "ensure_archive never finished"
        )

        assert.equal(cache .. "/nvim-portable-linux-x86_64.tar.gz", archive, err)
        assert.equal(2, #calls, "the checksum, then the archive")
        assert.equal(handler, calls[1].on_chunk)
        assert.equal(handler, calls[2].on_chunk)

        s:revert()
        vim.fn.delete(cache, "rf")
    end)

    it("passes no handler when none is given", function()
        local calls = {}
        local s = stub_download(calls)
        local cache = vim.fn.tempname()
        local archive, err

        release.ensure_archive("linux-x86_64", "v0.2.0", cache, function(path, ensure_err)
            archive, err = path, ensure_err
        end)

        assert.truthy(
            vim.wait(10000, function()
                return (archive or err) ~= nil
            end),
            "ensure_archive never finished"
        )

        assert.truthy(archive, err)
        assert.is_nil(calls[1].on_chunk)
        assert.is_nil(calls[2].on_chunk)

        s:revert()
        vim.fn.delete(cache, "rf")
    end)
end)

describe("release install pipeline progress", function()
    -- Drives the real release.install with the archive pipeline and the
    -- transport stubbed; the view and the collaborator calls share one event list.
    local function drive(state)
        local stubs = {}

        local view = helpers.recording_view()
        local events = view.events

        local function replace(module, name, impl)
            helpers.replace(stubs, module, name, impl)
        end

        local archive = vim.fn.tempname() .. ".tar.gz"

        vim.fn.writefile({ string.rep("x", 2048) }, archive, "b")

        replace(release, "ensure_archive", function(_, _, _, callback, on_chunk)
            table.insert(events, { kind = "call", name = "ensure_archive", on_chunk = on_chunk })

            if state.archive_err then
                callback(nil, state.archive_err)
                return
            end

            callback(archive, nil)
        end)

        replace(transport, "run", function(_, command, _, callback)
            local name = command:find("tar", 1, true) and "install" or "mkdir"

            table.insert(events, { kind = "call", name = name })

            if state.run_code then
                callback(state.run_code, "", state.run_err)
                return
            end

            callback(0, "", nil)
        end)

        replace(transport, "upload", function(_, local_path, remote_path, _, callback, on_chunk)
            table.insert(events, { kind = "call", name = "upload", on_chunk = on_chunk })

            if state.upload_err then
                callback(false, state.upload_err)
                return
            end

            callback(true, nil)
        end)

        local result, err

        release.install("outpost@box", "linux-x86_64", state.tag or "v0.2.0", {
            conn = {},
            view = view,
            cache_dir = "/unused",
        }, function(ok, install_err)
            result, err = ok, install_err
        end)

        for _, s in ipairs(stubs) do
            s:revert()
        end

        local names = {}

        for _, event in ipairs(events) do
            names[#names + 1] = event.kind == "phase" and ("phase: " .. event.text)
                or (event.kind == "call" and event.name or event.kind)
        end

        return result, err, events, names
    end

    it("opens at the pipeline's entry and banners each silent phase with its payload size", function()
        local result, err, _, names = drive {}

        assert.truthy(result, err)
        assert.are.same({
            "open",
            "phase: downloading the bundle",
            "ensure_archive",
            "mkdir",
            "phase: uploading the bundle - 2.0 KiB, no progress signal",
            "upload",
            "phase: extracting the bundle on the outpost - 2.0 KiB, no progress signal",
            "install",
        }, names)
    end)

    it("forwards raw download and upload output through the executor seam", function()
        local result, err, events = drive {}

        assert.truthy(result, err)

        local download_handler = events[3].on_chunk
        local upload_handler = events[6].on_chunk

        assert.truthy(download_handler, "the archive pipeline must carry a stream handler")
        assert.equal(download_handler, upload_handler, "one seam, one handler")

        download_handler("  12 40.0M   12 5120k    0     0   1.2M      0  0:00:33  0:00:04  0:00:29  1.3M\r", "stderr")
        upload_handler("scp: boom\n", "stderr")

        local streamed = {}

        for _, event in ipairs(events) do
            if event.kind == "stream" then
                table.insert(streamed, event.chunk .. "|" .. event.source)
            end
        end

        assert.are_same({
            "  12 40.0M   12 5120k    0     0   1.2M      0  0:00:33  0:00:04  0:00:29  1.3M\r|stderr",
            "scp: boom\n|stderr",
        }, streamed)
    end)

    it("fails at the upload without reaching the extract phase, owning no lifecycle", function()
        local result, err, events, names = drive { upload_err = "scp: permission denied" }

        assert.falsy(result)
        assert.equal("scp: permission denied", err)
        assert.are.same({
            "open",
            "phase: downloading the bundle",
            "ensure_archive",
            "mkdir",
            "phase: uploading the bundle - 2.0 KiB, no progress signal",
            "upload",
        }, names, "no extract banner, no succeed/fail - the command surface owns the lifecycle")
    end)

    it("runs silent and handler-free when no view is injected", function()
        local calls = {}
        local s = stub(release, "ensure_archive")
        local transport_run = stub(transport, "run")
        local transport_upload = stub(transport, "upload")

        s.invokes(function(_, _, _, callback, on_chunk)
            table.insert(calls, { on_chunk = on_chunk })
            callback("/tmp/archive.tar.gz", nil)
        end)
        transport_run.invokes(function(_, _, _, callback)
            callback(0, "", nil)
        end)
        transport_upload.invokes(function(_, _, _, _, callback, on_chunk)
            table.insert(calls, { on_chunk = on_chunk })
            callback(true, nil)
        end)

        local ok, err = unpack(await(release.install, nil, "outpost@box", "linux-x86_64", "v0.2.0", { conn = {} }))

        assert.truthy(ok, err)
        assert.is_nil(calls[1].on_chunk, "the archive pipeline runs handler-free without a view")
        assert.is_nil(calls[2].on_chunk, "scp runs handler-free without a view")

        s:revert()
        transport_run:revert()
        transport_upload:revert()
    end)

    it("refuses an unsafe tag before any window exists", function()
        local result, err, _, names = drive { tag = "../../etc" }

        assert.falsy(result)
        assert.truthy(err:find("unsafe release tag", 1, true))
        assert.equal(0, #names, "nothing opened, nothing announced")
    end)
end)
