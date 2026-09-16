-- The askpass bridge: how an `ssh` the control plane spawned asks the base
-- for a credential. A generated helper script plus a per-invocation pair of
-- FIFOs carry one answer in one direction; there is no RPC channel.

local config = require "outpost.config"

local M = {}

M.TIMEOUT = 60000

local CANCEL = "cancelled"
local TIMEOUT = "timed out"

local HELPER = [[#!/bin/sh
printf '%s\0%s\0' "$OUTPOST_ASKPASS_TOKEN" "$1" >"$OUTPOST_ASKPASS_ASK"
read -r A <"$OUTPOST_ASKPASS_ANSWER" && [ -n "$A" ] || exit 1
printf '%s\n' "$A"]]

-- Live bridges keyed by token, the prompts waiting for the one prompt that
-- is open, and the one endpoint whose prompt is open. `settled` drains
-- everything in flight after a cancel; it clears itself when the last
-- bridge closes.
local bridges = {}
local waiting = {}
local open
local settled = false
local counter = 0

local settle
local drain

-- Whether the bridge is installed: a per-connection or config override wins,
-- otherwise a UI must be attached to answer the prompt.
function M.enabled(opts)
    opts = opts or {}

    if opts.askpass ~= nil then
        return opts.askpass
    end

    local override = config.askpass()

    if override ~= nil then
        return override
    end

    return #vim.api.nvim_list_uis() > 0
end

-- The generated helper script: a few lines of sh, no secret, safe to cache.
function M.helper_script()
    return HELPER
end

-- Where the helper lives. The script carries no secret, so the cache
-- directory's permissions are not a credential concern.
function M.helper_path(opts)
    opts = opts or {}

    return vim.fs.joinpath(opts.askpass_cache or vim.fn.stdpath "cache", "outpost", "askpass.sh")
end

-- Generate the helper if it is missing or stale, and make it 0700.
function M.ensure_helper(opts)
    local path = M.helper_path(opts)
    local current = vim.fn.filereadable(path) == 1 and table.concat(vim.fn.readfile(path), "\n") or nil

    if current ~= HELPER then
        vim.fn.mkdir(vim.fs.dirname(path), "p")
        vim.fn.writefile(vim.split(HELPER, "\n"), path)
    end

    vim.uv.fs_chmod(path, 448)

    return path
end

-- The private directory the per-invocation FIFOs are minted in.
function M.dir(opts)
    opts = opts or {}

    local runtime = vim.env.XDG_RUNTIME_DIR
    local dir = opts.askpass_dir
        or (
            (runtime and runtime ~= "") and vim.fs.joinpath(runtime, "outpost")
            or vim.fs.joinpath(vim.fn.stdpath "state", "outpost")
        )

    vim.fn.mkdir(dir, "p")
    vim.uv.fs_chmod(dir, 448)

    return dir
end

-- Discriminate a prompt by its text: a host-key fingerprint asks for a
-- confirmation, everything else (including wording we do not recognise) for
-- a secret.
function M.prompt_kind(text)
    local lower = (text or ""):lower()

    if lower:find("fingerprint", 1, true) or lower:find("authenticity of host", 1, true) then
        return "confirm"
    end

    return "secret"
end

-- The blocking ask the base puts to the user. A cancelled input is an empty
-- answer, which the helper turns into a nonzero exit.
function M.prompt(kind, text, callback)
    if kind == "confirm" then
        local choice = vim.fn.confirm(text, "&Yes\n&No", 1)

        callback(choice == 1 and "yes" or choice == 2 and "no" or nil)
        return
    end

    local secret = vim.fn.inputsecret(text)

    callback(secret ~= "" and secret or nil)
end

local function mint_token()
    counter = counter + 1

    local entropy = vim.uv.random(16) or ""

    return vim.fn.sha256(entropy .. ("%d:%d"):format(counter, vim.uv.hrtime())):sub(1, 16)
end

local function mint_fifo(path)
    vim.fn.system { "mkfifo", "-m", "600", path }

    if vim.v.shell_error ~= 0 then
        return false
    end

    vim.uv.fs_chmod(path, 384)

    return true
end

-- Write one line to a bridge's answer FIFO. An empty line is the cancel
-- signal and makes the helper exit nonzero. The writer stays open until the
-- bridge closes: the helper's blocking open must always find a writer. The
-- secret is dropped as soon as it is written.
local function answer(bridge)
    if not bridge.answer_fd then
        bridge.answer_fd = vim.uv.fs_open(bridge.answer_path, "r+", 384)
    end

    if not bridge.answer_fd then
        return
    end

    vim.uv.fs_write(bridge.answer_fd, (bridge.value or "") .. "\n")

    bridge.value = nil
    bridge.answered = true
end

local function stop_timer(bridge)
    if bridge.timer then
        bridge.timer:stop()
        bridge.timer:close()
        bridge.timer = nil
    end
end

local function raise_next()
    if open or settled then
        return
    end

    local bridge = table.remove(waiting, 1)

    if not bridge or bridge.closed then
        return
    end

    open = bridge

    local kind = M.prompt_kind(bridge.text)

    bridge.timer = vim.uv.new_timer()
    bridge.timer:start(bridge.timeout or M.TIMEOUT, 0, function()
        vim.schedule(function()
            settle(bridge, nil, TIMEOUT)
        end)
    end)

    M.prompt(kind, bridge.text, function(value)
        vim.schedule(function()
            settle(bridge, value, value == nil and CANCEL or nil)
        end)
    end)
end

-- Resolve the open prompt: write the answer (or the empty cancel line) to
-- every bridge that joined it, then move on to the next queued endpoint.
settle = function(bridge, value, reason)
    if open ~= bridge then
        return
    end

    local joined = bridge.waiters
    open = nil

    stop_timer(bridge)

    for _, waiter in ipairs(joined) do
        if not waiter.closed then
            if value ~= nil then
                waiter.value = value
            else
                waiter.reason = reason
            end

            answer(waiter)
        end
    end

    bridge.waiters = {}

    if reason == CANCEL then
        settled = true
        drain()
    end

    raise_next()
end

-- Abandon every queued prompt after a cancel: no further prompts, and no
-- cascade of individual failures.
drain = function()
    local queued = waiting

    waiting = {}

    for _, bridge in ipairs(queued) do
        if not bridge.closed then
            bridge.reason = CANCEL
            answer(bridge)
        end
    end
end

local function request_prompt(bridge, text)
    if bridge.closed then
        return
    end

    bridge.text = text

    if settled then
        bridge.reason = CANCEL
        answer(bridge)
        return
    end

    if open then
        if open.endpoint == bridge.endpoint then
            table.insert(open.waiters, bridge)
            return
        end
    end

    -- An endpoint already waiting joins that prompt rather than raising a
    -- second one.
    for _, queued in ipairs(waiting) do
        if queued.endpoint == bridge.endpoint then
            table.insert(queued.waiters, bridge)
            return
        end
    end

    bridge.waiters = { bridge }
    table.insert(waiting, bridge)

    raise_next()
end

local function read_prompt(bridge)
    local fd = vim.uv.fs_open(bridge.ask_path, "r+", 384)

    if not fd then
        return
    end

    local pipe = vim.uv.new_pipe(false)

    pipe:open(fd)
    bridge.pipe = pipe

    pipe:read_start(function(_, data)
        if not data then
            return
        end

        bridge.buffer = (bridge.buffer or "") .. data

        local first = bridge.buffer:find("\0", 1, true)
        local second = first and bridge.buffer:find("\0", first + 1, true)

        if not second then
            return
        end

        local token = bridge.buffer:sub(1, first - 1)
        local text = bridge.buffer:sub(first + 1, second - 1)

        bridge.buffer = nil

        -- the token names one in-flight request; a consumed or unknown one
        -- is refused rather than answered
        if token ~= bridge.token then
            bridge.reason = "unknown askpass token"
            bridge.token = nil
            answer(bridge)
            return
        end

        bridge.token = nil

        -- the read callback is a fast event; the prompt is not
        vim.schedule(function()
            request_prompt(bridge, text)
        end)
    end)
end

-- Start a bridge for one invocation: two 0600 FIFOs with random names in a
-- 0700 directory, and a reader waiting for the helper's prompt. Returns the
-- env table to attach to `vim.system` plus a close() that unlinks the FIFOs
-- and returns the reason the bridge failed, if it did.
function M.env(endpoint, opts)
    opts = opts or {}

    if not M.enabled(opts) then
        return nil
    end

    local helper = M.ensure_helper(opts)
    local dir = M.dir(opts)
    local token = mint_token()
    local ask_path = vim.fs.joinpath(dir, token .. ".ask")
    local answer_path = vim.fs.joinpath(dir, token .. ".answer")

    if not (mint_fifo(ask_path) and mint_fifo(answer_path)) then
        vim.uv.fs_unlink(ask_path)
        vim.uv.fs_unlink(answer_path)
        vim.notify("outpost: could not create the askpass FIFOs", vim.log.levels.ERROR)
        return nil
    end

    local bridge = {
        endpoint = endpoint,
        token = token,
        ask_path = ask_path,
        answer_path = answer_path,
        timeout = opts.askpass_timeout,
    }

    read_prompt(bridge)

    bridges[token] = bridge

    local env = {
        SSH_ASKPASS = helper,
        SSH_ASKPASS_REQUIRE = "force",
        OUTPOST_ASKPASS_ASK = ask_path,
        OUTPOST_ASKPASS_ANSWER = answer_path,
        OUTPOST_ASKPASS_TOKEN = token,
    }

    local function close()
        if bridge.closed then
            return bridge.reason
        end

        bridge.closed = true

        stop_timer(bridge)

        if bridge.pipe then
            bridge.pipe:read_stop()
            bridge.pipe:close()
            bridge.pipe = nil
        end

        if bridge.answer_fd then
            vim.uv.fs_close(bridge.answer_fd)
            bridge.answer_fd = nil
        end

        vim.uv.fs_unlink(ask_path)
        vim.uv.fs_unlink(answer_path)

        bridges[token] = nil

        for index, queued in ipairs(waiting) do
            if queued == bridge then
                table.remove(waiting, index)
                break
            end
        end

        if open == bridge then
            settle(bridge, nil, CANCEL)
        elseif open then
            for index, joined in ipairs(open.waiters) do
                if joined == bridge then
                    table.remove(open.waiters, index)
                    break
                end
            end
        end

        if settled and next(bridges) == nil then
            settled = false
        end

        return bridge.reason
    end

    return env, close
end

return M
