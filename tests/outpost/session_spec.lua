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
        assert.matches("%.cache/outpost/run/ab12cd/server%.pid$", paths.pid)
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

    it("records the server's pid so stop can find it later", function()
        assert.truthy(command:find "server%.pid")
        assert.truthy(command:find "%$!", "must capture the backgrounded server's pid")
    end)

    it("relocates the XDG environment before the project directory is touched", function()
        local relocation_at = command:find("OUTPOST_ORIG_XDG_CONFIG_HOME", 1, true)
        local cd_at = command:find("cd '/home/o/proj'", 1, true)

        assert.truthy(relocation_at and cd_at and relocation_at < cd_at)
    end)

    it("forces NVIM_APPNAME=nvim so the relocated config dir is always config/nvim", function()
        assert.truthy(command:find("NVIM_APPNAME=nvim", 1, true))
    end)

    it("launches with a post-config restore fragment via -c, not --cmd", function()
        assert.falsy(command:find("--cmd", 1, true), "a --cmd restore runs before config resolves its own path")
        assert.truthy(command:find("-c 'lua " .. session.build_xdg_restore_fragment(), 1, true))
    end)
end)

describe("session XDG relocation (sh fragment, run behaviorally)", function()
    local fragment = session.build_xdg_relocation()

    -- run the fragment under a real shell with a controlled env, then
    -- inspect the resulting exports via `env` - the sh idiom for "is a var
    -- set or unset" only proves itself by executing, not by reading text
    local function run(env_prefix)
        return vim.fn.system { "sh", "-c", env_prefix .. "\n" .. fragment .. "\nenv" }
    end

    it("relocates all four XDG vars into the outpost root", function()
        -- `env` shows the shell-expanded value, so match the suffix rather
        -- than the literal "$HOME" text used in the fragment itself
        local out = run ""

        assert.truthy(out:find "XDG_CONFIG_HOME=.*/%.cache/outpost/config\n")
        assert.truthy(out:find "XDG_DATA_HOME=.*/%.cache/outpost/data\n")
        assert.truthy(out:find "XDG_STATE_HOME=.*/%.cache/outpost/state\n")
        assert.truthy(out:find "XDG_CACHE_HOME=.*/%.cache/outpost/cache\n")
        assert.truthy(out:find("NVIM_APPNAME=nvim", 1, true))
    end)

    it("captures an originally-set value under OUTPOST_ORIG_XDG_*", function()
        local out = run "export XDG_CONFIG_HOME=/account/cfg"

        assert.truthy(out:find("OUTPOST_ORIG_XDG_CONFIG_HOME=/account/cfg", 1, true))
    end)

    it("leaves OUTPOST_ORIG_XDG_* unset when the account var was never set", function()
        local out = run "unset XDG_CONFIG_HOME"

        assert.falsy(out:find("OUTPOST_ORIG_XDG_CONFIG_HOME", 1, true))
    end)

    it("captures a set-but-empty value as set, not as unset", function()
        local out = run "export XDG_DATA_HOME="

        assert.truthy(out:find("OUTPOST_ORIG_XDG_DATA_HOME=", 1, true))
    end)
end)

describe("session XDG restore fragment (nvim -c, run behaviorally)", function()
    local fragment = session.build_xdg_restore_fragment()

    -- the fragment's job is entirely about what children see, so the proof
    -- is a real spawned child's environment, not a read of vim.env
    local function child_env(setup_env, var)
        local cmd = setup_env
            .. " nvim --headless -u NONE -c 'lua "
            .. fragment
            .. "' -c 'lua io.write(vim.fn.system(\"printenv "
            .. var
            .. "\"))' -c 'qa!' 2>/dev/null"

        return vim.trim(vim.fn.system { "sh", "-c", cmd })
    end

    it("restores a captured original for children", function()
        local out = child_env("OUTPOST_ORIG_XDG_CONFIG_HOME=/account/cfg", "XDG_CONFIG_HOME")

        assert.equal("/account/cfg", out)
    end)

    it("unsets a var that was originally unset, even if relocation set it", function()
        local out = child_env("XDG_CONFIG_HOME=/outpost/cfg", "XDG_CONFIG_HOME")

        assert.equal("", out)
    end)

    it("hides OUTPOST_SESSION from children", function()
        local out = child_env("OUTPOST_SESSION=1", "OUTPOST_SESSION")

        assert.equal("", out)
    end)
end)

describe("session stop command", function()
    local command = session.build_stop_command "ab12cd"

    it("tolerates a missing pidfile: nothing to kill is not an error", function()
        assert.truthy(command:find "server%.pid")
    end)

    it("sends TERM first, escalating to KILL only if still alive", function()
        assert.truthy(command:find("TERM", 1, true))
        assert.truthy(command:find("KILL", 1, true))
    end)

    it("removes the session directory once the process is gone", function()
        assert.truthy(command:find "rm %-rf")
        assert.truthy(command:find("run/ab12cd", 1, true))
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

describe("session UI takeover", function()
    it("correlates attached UIs with the channel ids chanclose needs", function()
        local listing = vim.json.encode {
            { width = 80, height = 24, chan = 3 },
            { width = 120, height = 40, chan = 7 },
        }

        assert.same({ 3, 7 }, session.attached_channels(listing))
    end)

    it("finds no channels when no UI is attached", function()
        assert.same({}, session.attached_channels "[]")
    end)

    it("ignores UI entries that carry no channel id", function()
        local listing = vim.json.encode { { width = 80, height = 24 } }

        assert.same({}, session.attached_channels(listing))
    end)

    it("rejects an unreadable listing instead of closing the wrong channel", function()
        local chans, err = session.attached_channels "not json"

        assert.is_nil(chans)
        assert.truthy(err)
    end)

    it("closes one channel by id, tolerating a channel that already went away", function()
        local command = session.close_command(12)

        assert.truthy(command:find("chanclose", 1, true))
        assert.truthy(command:find("12", 1, true))
    end)
end)

-- The remote command runs under the user's login shell, which is frequently
-- zsh. zsh does not word-split unquoted variables, so the probe must not
-- build its command from a `$VAR` (`$TO nvim ...` breaks there).
describe("session probe under a non-POSIX login shell", function()
    local home
    local socket
    local pipe

    before_each(function()
        home = vim.fn.tempname()

        local bin = vim.fs.joinpath(home, ".cache/outpost/install/current/bin/nvim")

        vim.fn.mkdir(vim.fs.dirname(bin), "p")
        vim.fn.writefile({ "#!/bin/sh", "exit 0" }, bin)
        vim.uv.fs_chmod(bin, 493)

        socket = session.paths("ab12cd", home).socket
        vim.fn.mkdir(vim.fs.dirname(socket), "p")

        pipe = vim.uv.new_pipe(false)
        pipe:bind(socket)
    end)

    after_each(function()
        if pipe then
            pipe:close()
        end

        vim.fn.delete(home, "rf")
    end)

    it("reports live when the socket answers, even when run by zsh", function()
        if vim.fn.executable "zsh" ~= 1 then
            pending "zsh not installed"
            return
        end

        local command = "export HOME='" .. home .. "'\n" .. session.build_probe_command "ab12cd"

        assert.equal("live 1", vim.trim(vim.fn.system { "zsh", "-c", command }))
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

    it("parses the stop command", function()
        assert.truthy(sh_syntax_ok(session.build_stop_command "ab12cd"))
    end)

    it("parses the start command for a project path full of shell metacharacters", function()
        local hostile = [[/home/o/it's "$HOME" `whoami` %s; & | > file]]
        local command = session.build_start_command("ab12cd", hostile, "outpost@box")

        assert.truthy(sh_syntax_ok(command))
        -- the path is embedded single-quoted, so the shell must not expand it
        assert.truthy(command:find("'" .. hostile:gsub("'", "'\\''") .. "'", 1, true))
    end)
end)
