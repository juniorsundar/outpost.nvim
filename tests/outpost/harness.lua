-- Test harness for integration specs.

local M = {}

local function env(name, default)
    return os.getenv(name) or default
end

function M.host()
    return env("OUTPOST_TEST_HOST", "127.0.0.1")
end

function M.port()
    return env("OUTPOST_TEST_PORT", "2222")
end

function M.user()
    return env("OUTPOST_TEST_USER", "outpost")
end

-- The password-authenticating account: no key, reachable only by password
-- through the askpass bridge. The key-based account above is untouched.
function M.pass_user()
    return env("OUTPOST_TEST_PASS_USER", "outpass")
end

function M.password()
    return env("OUTPOST_TEST_PASSWORD", "fixture-password")
end

function M.key()
    return env("OUTPOST_TEST_KEY", "tests/outpost/.keys/id_ed25519")
end

function M.known_hosts()
    return env("OUTPOST_TEST_KNOWN_HOSTS", "tests/outpost/.keys/known_hosts")
end

-- "user@host" target form (no path), as accepted by the plugin.
function M.target()
    return M.user() .. "@" .. M.host()
end

-- The password account's target form, likewise without a path.
function M.pass_target()
    return M.pass_user() .. "@" .. M.host()
end

-- The full non-interactive ssh option set for talking to the fixture.
function M.ssh_args()
    return require("outpost.transport").ssh_args {
        port = M.port(),
        key = M.key(),
        known_hosts = M.known_hosts(),
        askpass = false,
    }
end

-- scp variant: identical options, but scp spells the port flag "-P".
function M.scp_args()
    local args = {}

    for _, arg in ipairs(M.ssh_args()) do
        table.insert(args, arg == "-p" and "-P" or arg)
    end

    return args
end

-- Run a command on the fixture over ssh; returns { out, code }.
function M.remote(command)
    local argv = { "ssh" }

    require("outpost.transport").ensure_mux_dir()
    vim.list_extend(argv, M.ssh_args())
    table.insert(argv, M.target())
    table.insert(argv, command)

    local out = vim.fn.system(argv)

    return { out = out, code = vim.v.shell_error }
end

function M.is_up()
    return M.remote("true").code == 0
end

local ready = false

-- Unit runs never probe SSH. Explicit integration runs fail rather than
-- silently losing coverage when the fixture is unavailable.
function M.pending_unless_up()
    if vim.env.OUTPOST_TEST_INTEGRATION ~= "1" then
        pending "integration disabled - run `make test-integration`"
        return false
    end

    if not ready then
        assert(M.is_up(), "harness not running - run `make harness-up`")
        if vim.env.OUTPOST_TEST_LIVE_RELEASE ~= "1" then
            require("outpost.release_fixture").use()
        end
        ready = true
    end

    return true
end

return M
