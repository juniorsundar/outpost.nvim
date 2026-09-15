-- Unit specs for down's pure command building (offline: no network, valid
-- POSIX sh checked the same way session_spec.lua checks its commands).

local down = require "outpost.down"

describe("down teardown command", function()
    local command = down.build_teardown_command()

    it("kills every live session's recorded pid before removing anything", function()
        assert.truthy(command:find "server%.pid")
        assert.truthy(command:find("kill", 1, true))
    end)

    it("removes the entire outpost cache directory", function()
        assert.truthy(command:find "rm %-rf")
        assert.truthy(command:find "%.cache/outpost")
    end)
end)

describe("down teardown command is valid POSIX sh", function()
    it("parses with sh -n", function()
        local path = vim.fn.tempname() .. ".sh"

        vim.fn.writefile(vim.split(down.build_teardown_command(), "\n"), path)
        vim.fn.system { "sh", "-n", path }

        local code = vim.v.shell_error

        vim.fn.delete(path)

        assert.equal(0, code)
    end)
end)
