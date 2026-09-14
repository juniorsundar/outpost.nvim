-- Unit specs for the session lifecycle module (offline by construction:
-- pure builders with injected values - no network, no fixture).

local session = require "outpost.session"

describe("session paths", function()
    it("places the socket, log, and manifest under the per-session run directory", function()
        local paths = session.paths "ab12cd"

        assert.matches("%.cache/outpost/run/ab12cd$", paths.root)
        assert.matches("%.cache/outpost/run/ab12cd/server%.sock$", paths.socket)
        assert.matches("%.cache/outpost/run/ab12cd/server%.log$", paths.log)
        assert.matches("%.cache/outpost/run/ab12cd/manifest%.json$", paths.manifest)
        assert.equal(paths.root, vim.fs.dirname(paths.socket))
    end)
end)

describe("session manifest", function()
    it("records the canonical path, endpoint, and creation time as JSON", function()
        local ok, manifest = pcall(vim.json.decode, session.manifest_json("/home/o/proj", "outpost@box", 1234))

        assert.truthy(ok, "manifest must be valid JSON")
        assert.equal("/home/o/proj", manifest.canonical_path)
        assert.equal("outpost@box", manifest.endpoint)
        assert.equal(1234, manifest.created)
    end)

    it("escapes quote-bearing project paths", function()
        local ok, manifest = pcall(vim.json.decode, session.manifest_json('/home/o/it\'s "proj"', "outpost@box", 1))

        assert.truthy(ok, "a quote in the path must not break the JSON")
        assert.equal('/home/o/it\'s "proj"', manifest.canonical_path)
    end)
end)

describe("session start command", function()
    local command = session.build_start_command("ab12cd", "/home/o/proj", "outpost@box")

    it("runs private: umask 077 before anything is created", function()
        assert.truthy(command:find("umask 077", 1, true))
    end)

    it("asserts the session directory's 0700 explicitly, not just via umask", function()
        assert.truthy(command:find("chmod 700", 1, true))
    end)

    it("sweeps a stale session directory before starting fresh", function()
        assert.truthy(command:find("rm -rf", 1, true))
    end)

    it("runs the server with cwd = the canonical project path", function()
        assert.truthy(command:find("cd '/home/o/proj'", 1, true))
    end)

    it("writes the manifest into the session directory", function()
        local manifest = session.manifest_json("/home/o/proj", "outpost@box", os.time())

        assert.truthy(command:find(manifest:sub(1, 30), 1, true), "manifest JSON must be embedded")
        assert.truthy(command:find("manifest.json", 1, true))
    end)

    it("exports OUTPOST_SESSION=1 for the server", function()
        assert.truthy(command:find("OUTPOST_SESSION=1", 1, true))
    end)

    it("starts a headless server listening on the session socket", function()
        assert.truthy(command:find("--headless", 1, true))
        assert.truthy(command:find("--listen", 1, true))
        assert.truthy(command:find("$HOME/.cache/outpost/run/ab12cd/server.sock", 1, true))
    end)

    it("forces the socket to 0600 once it exists", function()
        assert.truthy(command:find("chmod 600", 1, true))
    end)

    it("fails loudly when the socket never appears", function()
        assert.truthy(command:find("outpost-session-start-failed", 1, true))
    end)
end)

describe("session probe command", function()
    local command = session.build_probe_command "ab12cd"

    it("rides the established probe pattern: the outpost's own nvim over ssh", function()
        assert.truthy(command:find(".cache/outpost/install/current/bin/nvim", 1, true))
        assert.truthy(command:find("--server", 1, true))
        assert.truthy(command:find("--remote-expr", 1, true))
        assert.truthy(command:find("$HOME/.cache/outpost/run/ab12cd/server.sock", 1, true))
    end)

    it("reports live with the prior-session marker when the server answers", function()
        assert.truthy(command:find("live", 1, true))
    end)

    it("reports dead, marking whether a session was there before", function()
        assert.truthy(command:find("dead", 1, true))
        assert.truthy(command:find("manifest.json", 1, true))
    end)
end)

-- The generated commands are POSIX sh for an outpost we do not control: a
-- syntax error must be caught here, not as a mysterious remote failure.
describe("generated remote commands are valid POSIX sh", function()
    local function sh_syntax_ok(script)
        local path = vim.fn.tempname() .. ".sh"

        vim.fn.writefile(vim.split(script, "\n"), path)

        vim.fn.system { "sh", "-n", path }

        local code = vim.v.shell_error

        vim.fn.delete(path)

        return code == 0
    end

    it("parses the session start command", function()
        assert.truthy(sh_syntax_ok(session.build_start_command("ab12cd", "/home/o/proj", "outpost@box")))
    end)

    it("parses the probe command", function()
        assert.truthy(sh_syntax_ok(session.build_probe_command "ab12cd"))
    end)

    it("parses the start command for a project path full of shell metacharacters", function()
        local hostile = [[/home/o/it's "$HOME" `whoami` %s; & | > file]]
        local command = session.build_start_command("ab12cd", hostile, "outpost@box")

        assert.truthy(sh_syntax_ok(command))
        -- the path is embedded single-quoted, so the shell must not expand it
        assert.truthy(command:find("'" .. hostile:gsub("'", "'\\''") .. "'", 1, true))
    end)
end)
