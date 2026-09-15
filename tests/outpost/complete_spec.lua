-- Unit spec for completion candidates (offline: temp registry + temp ssh
-- config, no network).

local complete = require "outpost.complete"
local registry = require "outpost.registry"

describe("completion", function()
    local dir
    local ssh_config

    before_each(function()
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        ssh_config = vim.fn.tempname()

        vim.fn.writefile({ "Host devbox", "Host alpha" }, ssh_config)

        registry.record(dir, {
            session_id = "00ac56",
            endpoint = "dev@10.0.0.4",
            canonical_path = "/srv/proj",
            typed_target = "dev@fixturebox:~/code/proj",
        })
    end)

    after_each(function()
        vim.fn.delete(dir, "rf")
        vim.fn.delete(ssh_config)
    end)

    it("offers the subcommands", function()
        assert.are_same({ "up", "update", "list", "stop", "down" }, complete.subcommands())
    end)

    it("offers ssh-config hosts, then registry session ids and targets", function()
        assert.are_same(
            { "devbox", "alpha", "00ac56", "dev@fixturebox:~/code/proj" },
            complete.up("", { registry_dir = dir, ssh_config = ssh_config })
        )
    end)

    it("filters up candidates by the leading text", function()
        assert.are_same(
            { "devbox", "dev@fixturebox:~/code/proj" },
            complete.up("dev", { registry_dir = dir, ssh_config = ssh_config })
        )
    end)

    it("falls back to endpoint plus path for a target", function()
        local bare = vim.fn.tempname()

        vim.fn.mkdir(bare, "p")
        registry.record(bare, {
            session_id = "bbbbbb",
            endpoint = "dev@10.0.0.4",
            canonical_path = "/srv/proj",
        })

        local candidates = complete.up("", { registry_dir = bare, ssh_config = ssh_config })

        assert.truthy(vim.tbl_contains(candidates, "dev@10.0.0.4:/srv/proj"))
        vim.fn.delete(bare, "rf")
    end)

    it("offers known hosts for update, deduped", function()
        registry.record(dir, {
            session_id = "cccccc",
            endpoint = "dev@10.0.0.4",
            canonical_path = "/srv/other",
            typed_target = "dev@devbox:~/other",
        })

        assert.are_same(
            { "devbox", "alpha", "fixturebox" },
            complete.hosts("", { registry_dir = dir, ssh_config = ssh_config })
        )
    end)

    it("returns nothing when there are no known hosts", function()
        local empty = vim.fn.tempname()

        vim.fn.mkdir(empty, "p")

        assert.are_same({}, complete.hosts("", { registry_dir = empty, ssh_config = empty .. ".none" }))
        vim.fn.delete(empty, "rf")
    end)

    it("offers every registered session id for stop, with no state filter", function()
        assert.are_same({ "00ac56" }, complete.stop("", { registry_dir = dir }))
    end)

    it("filters stop candidates by the leading text", function()
        assert.are_same({}, complete.stop("zz", { registry_dir = dir }))
    end)
end)
