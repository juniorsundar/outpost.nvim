-- Unit spec for the attach script: paths and rendering, offline by
-- construction (pure functions with injected values).

local attach = require "outpost.attach"

local function identity(overrides)
    return vim.tbl_extend("force", {
        session_id = "ab12cd",
        endpoint = "outpost@box",
        client = "/cache/clients/linux-x86_64/v0.12.5/bin/nvim",
        local_socket = "/cache/outpost/attach/ab12cd.sock",
        remote_socket = "/home/outpost/.cache/outpost/run/ab12cd/server.sock",
        conn = {},
    }, overrides or {})
end

local function sh_syntax_ok(script)
    local path = vim.fn.tempname() .. ".sh"

    vim.fn.writefile(vim.split(script, "\n"), path)
    vim.fn.system { "sh", "-n", path }

    local code = vim.v.shell_error

    vim.fn.delete(path)

    return code == 0
end

describe("attach script paths", function()
    it("names the script by session id under the attach cache directory", function()
        assert.equal("/cache/outpost/attach/ab12cd.sh", attach.path("ab12cd", "/cache/outpost/attach"))
    end)

    it("places the tunneled local socket alongside the script, keyed by session", function()
        assert.equal("/cache/outpost/attach/ab12cd.sock", attach.socket_path("ab12cd", "/cache/outpost/attach"))
    end)
end)

describe("attach script preparation", function()
    local tmp

    before_each(function()
        tmp = vim.fn.tempname()
        vim.fn.mkdir(tmp, "p")
    end)

    after_each(function()
        vim.fn.delete(tmp, "rf")
    end)

    it("writes an executable script at the session's path", function()
        local path = attach.prepare(identity(), { attach_dir = tmp })

        assert.equal(attach.path("ab12cd", tmp), path)
        assert.equal(1, vim.fn.executable(path), "the user must be able to run the path as-is")
        assert.truthy(vim.fn.readfile(path)[1]:find("^#!", 1), "the script must be readable from disk")
    end)

    it("sweeps a stale local socket for the session before handing out the script", function()
        local stale = attach.socket_path("ab12cd", tmp)

        vim.fn.mkdir(vim.fs.dirname(stale), "p")
        vim.fn.writefile({ "stale" }, stale)
        assert.truthy(vim.uv.fs_stat(stale))

        attach.prepare(identity(), { attach_dir = tmp })

        assert.falsy(vim.uv.fs_stat(stale), "a stale socket must be swept at generation time")
    end)
end)

describe("attach script rendering", function()
    local script = attach.render(identity())

    it("is a self-contained executable script", function()
        assert.truthy(script:find "^#!%s*/bin/sh")
    end)

    it("opens its own ssh tunnel that fails when a forward cannot be set up", function()
        assert.truthy(script:find("ssh", 1, true))
        assert.truthy(script:find("ExitOnForwardFailure=yes", 1, true))
        assert.truthy(script:find("-L", 1, true))
    end)

    it("forwards the session's local socket to the remote session socket", function()
        assert.truthy(script:find("/cache/outpost/attach/ab12cd.sock", 1, true))
        assert.truthy(script:find("/home/outpost/.cache/outpost/run/ab12cd/server.sock", 1, true))
    end)

    it("reaches the outpost through the resolved endpoint", function()
        assert.truthy(script:find("outpost@box", 1, true))
    end)

    it("execs the pinned attach client in remote-ui mode against the tunneled socket", function()
        assert.truthy(script:find("/cache/clients/linux-x86_64/v0.12.5/bin/nvim", 1, true))
        assert.truthy(script:find("--remote-ui", 1, true))
        assert.truthy(script:find("--server", 1, true))
    end)

    it("keeps the attach client in the foreground so it owns the terminal", function()
        -- a trailing `&` would give the client /dev/null on stdin (POSIX
        -- async), so it would exit at once and leak terminal replies
        assert.truthy(script:find('"$CLIENT" --remote-ui --server "$SOCK"', 1, true))
        assert.falsy(script:find('"$CLIENT" --remote-ui --server "$SOCK" &', 1, true))
    end)

    it("tears its tunnel down on exit and termination", function()
        assert.truthy(script:find("trap", 1, true))
        assert.truthy(script:find("EXIT", 1, true))
        assert.truthy(script:find("TERM", 1, true))
        assert.truthy(script:find('kill "$TUNNEL"', 1, true))
        assert.truthy(script:find('rm -f "$SOCK"', 1, true))
    end)

    it("fails loudly instead of hanging when the tunnel dies first", function()
        assert.truthy(script:find("kill -0", 1, true))
        assert.truthy(script:find("outpost-attach-failed", 1, true))
    end)

    it("embeds the connection details the plugin talks to the outpost with", function()
        local with_conn = attach.render(identity {
            conn = { port = "2222", key = "/keys/id_ed25519", known_hosts = "/keys/known_hosts" },
        })

        assert.truthy(sh_syntax_ok(with_conn))
        assert.truthy(with_conn:find("-p", 1, true))
        assert.truthy(with_conn:find("2222", 1, true))
        assert.truthy(with_conn:find("/keys/id_ed25519", 1, true))
        assert.truthy(with_conn:find("/keys/known_hosts", 1, true))
    end)

    it("opens its own tunnel instead of reusing a multiplexed connection", function()
        local script = attach.render(identity { conn = { mux = true, mux_path = "/mux/%C" } })

        assert.truthy(sh_syntax_ok(script))
        -- a muxed -L would be owned by the shared master, not the script
        assert.truthy(script:find("ControlMaster=no", 1, true))
        assert.falsy(script:find("ControlMaster=auto", 1, true))
        assert.falsy(script:find("ControlPath=/mux/%C", 1, true))
    end)

    it("stays valid POSIX sh for values full of shell metacharacters", function()
        local hostile = [[/home/o/it's "$HOME" `whoami` %s; & | > file]]
        local hostile_script = attach.render(identity {
            client = hostile,
            local_socket = hostile,
            remote_socket = hostile,
            endpoint = hostile,
        })

        assert.truthy(sh_syntax_ok(hostile_script))
        -- single-quoted, so the shell must not expand or split it
        assert.truthy(hostile_script:find("'" .. hostile:gsub("'", "'\\''") .. "'", 1, true))
    end)
end)
