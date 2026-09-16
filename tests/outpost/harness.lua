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

-- The full non-interactive ssh option set for talking to the fixture.
function M.ssh_args()
    return {
        "-p",
        M.port(),
        "-i",
        M.key(),
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        "UserKnownHostsFile=" .. M.known_hosts(),
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=2",
        "-o",
        "NumberOfPasswordPrompts=1",
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

    vim.list_extend(argv, M.ssh_args())
    table.insert(argv, M.target())
    table.insert(argv, command)

    local out = vim.fn.system(argv)

    return { out = out, code = vim.v.shell_error }
end

function M.is_up()
    return M.remote("true").code == 0
end

-- Call at the top of any fixture-dependent test. Marks the test pending
-- (not failed) when the harness is not running.
function M.pending_unless_up()
    if not M.is_up() then
        pending "harness not running - run `make harness-up` (requires docker)"
        return false
    end

    return true
end

return M
