-- Unit specs for remote run/ enumeration (offline: pure parsing of injected
-- listing output; the command builder is checked for valid POSIX sh, same
-- convention as session_spec.lua).

local scan = require "outpost.scan"

describe("scan parse", function()
    it("parses one session with a manifest", function()
        local output = "ab12cd\t"
            .. vim.json.encode { canonical_path = "/home/o/proj", endpoint = "outpost@box", created = 1234 }

        local entries = scan.parse(output)

        assert.equal(1, #entries)
        assert.equal("ab12cd", entries[1].session_id)
        assert.equal("/home/o/proj", entries[1].canonical_path)
        assert.equal("outpost@box", entries[1].endpoint)
        assert.equal(1234, entries[1].created)
    end)

    it("parses multiple sessions", function()
        local manifest_a = vim.json.encode { canonical_path = "/a", endpoint = "outpost@box", created = 1 }
        local manifest_b = vim.json.encode { canonical_path = "/b", endpoint = "outpost@box", created = 2 }
        local output = ("ab12cd\t%s\n34ef56\t%s\n"):format(manifest_a, manifest_b)

        local entries = scan.parse(output)

        assert.equal(2, #entries)
        assert.equal("ab12cd", entries[1].session_id)
        assert.equal("34ef56", entries[2].session_id)
    end)

    it("includes a session id with no manifest, without crashing", function()
        local entries = scan.parse "ab12cd\t\n"

        assert.equal(1, #entries)
        assert.equal("ab12cd", entries[1].session_id)
        assert.is_nil(entries[1].canonical_path)
    end)

    it("includes a session id whose manifest is unreadable JSON", function()
        local entries = scan.parse "ab12cd\tnot json\n"

        assert.equal(1, #entries)
        assert.equal("ab12cd", entries[1].session_id)
        assert.is_nil(entries[1].canonical_path)
    end)

    it("finds nothing in empty output", function()
        assert.same({}, scan.parse "")
    end)
end)

describe("scan command is valid POSIX sh", function()
    it("parses with sh -n", function()
        local path = vim.fn.tempname() .. ".sh"

        vim.fn.writefile(vim.split(scan.build_scan_command(), "\n"), path)
        vim.fn.system { "sh", "-n", path }

        local code = vim.v.shell_error

        vim.fn.delete(path)

        assert.equal(0, code)
    end)
end)
