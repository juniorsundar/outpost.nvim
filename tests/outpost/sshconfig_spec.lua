-- Unit spec for ssh-config host parsing (offline by construction).

local sshconfig = require "outpost.sshconfig"

describe("sshconfig", function()
    describe("hosts", function()
        it("returns literal host aliases in file order", function()
            local text = table.concat({
                "Host devbox",
                "  HostName 10.0.0.4",
                "  User dev",
                "Host vps staging",
                "  HostName 10.0.0.5",
            }, "\n")

            assert.are_same({ "devbox", "vps", "staging" }, sshconfig.hosts(text))
        end)

        it("skips wildcard patterns and negations", function()
            local text = table.concat({
                "Host *",
                "  User fallback",
                "Host prod-?",
                "Host !excluded real",
            }, "\n")

            assert.are_same({ "real" }, sshconfig.hosts(text))
        end)

        it("dedupes repeated aliases, keeping the first occurrence", function()
            local text = table.concat({
                "Host devbox",
                "Host other",
                "Host devbox",
            }, "\n")

            assert.are_same({ "devbox", "other" }, sshconfig.hosts(text))
        end)

        it("ignores comments, blank lines, and non-Host directives", function()
            local text = table.concat({
                "# a comment",
                "",
                "  User someone",
                "Host actual # trailing note",
                "HostName nope.example",
            }, "\n")

            assert.are_same({ "actual" }, sshconfig.hosts(text))
        end)

        it("matches the Host keyword case-insensitively", function()
            assert.are_same({ "mixed" }, sshconfig.hosts "host mixed")
        end)

        it("returns nothing for empty or Hostless text", function()
            assert.are_same({}, sshconfig.hosts "")
            assert.are_same({}, sshconfig.hosts "User dev\nPort 22\n")
        end)
    end)

    describe("read", function()
        it("reads aliases from a config file", function()
            local path = vim.fn.tempname()

            vim.fn.writefile({ "Host devbox", "Host vps" }, path)

            assert.are_same({ "devbox", "vps" }, sshconfig.read(path))
            vim.fn.delete(path)
        end)

        it("reads as no hosts when the file is missing", function()
            assert.are_same({}, sshconfig.read(vim.fn.tempname() .. ".missing"))
        end)
    end)
end)
