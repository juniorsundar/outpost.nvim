-- Unit spec for the pure helpers of the release pipeline (offline by
-- construction).

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
