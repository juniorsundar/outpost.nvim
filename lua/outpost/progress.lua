-- The progress view: the read-only bottom-split window one long-haul
-- operation opens for itself; its outcome never depends on the window.

local M = {}

local WIN_HEIGHT = 8
local CLOCK_PERIOD = 1000

-- "59s" inside the first minute, then a clock face.
function M.format_elapsed(seconds)
    seconds = math.max(math.floor(seconds or 0), 0)

    if seconds < 60 then
        return ("%ds"):format(seconds)
    end

    return ("%d:%02d"):format(seconds / 60, seconds % 60)
end

-- A handle that changes nothing: headless nvim, and any call site that
-- has no operation of its own, gets one of these.
function M.null()
    return {
        phase = function() end,
        open = function() end,
        stream = function() end,
        succeed = function() end,
        fail = function() end,
    }
end

local function now()
    return vim.uv.now()
end

-- A wiped buffer (the user closed the window) makes the handle inert.
local function alive(handle)
    if handle.dead then
        return false
    end

    if not vim.api.nvim_buf_is_valid(handle.buf) then
        handle.dead = true
        return false
    end

    return true
end

local function stop_clock(handle)
    if not handle.timer then
        return
    end

    handle.timer:stop()

    if not handle.timer:is_closing() then
        handle.timer:close()
    end

    handle.timer = nil
end

-- A phase line renders its own elapsed time, frozen once the phase ends.
local function text_of(entry)
    if entry.kind ~= "phase" then
        return entry.text
    end

    return ("%s (%s)"):format(entry.text, M.format_elapsed(((entry.frozen or now()) - entry.started) / 1000))
end

local function render_line(handle, index)
    if not alive(handle) then
        return
    end

    pcall(function()
        vim.bo[handle.buf].modifiable = true
        vim.api.nvim_buf_set_lines(handle.buf, index - 1, index, false, { text_of(handle.lines[index]) })
        vim.bo[handle.buf].modifiable = false
    end)
end

local function append(handle, entry)
    table.insert(handle.lines, entry)

    if not alive(handle) then
        return
    end

    pcall(function()
        local at = #handle.lines

        vim.bo[handle.buf].modifiable = true

        if at == 1 then
            vim.api.nvim_buf_set_lines(handle.buf, 0, 1, false, { text_of(entry) })
        else
            vim.api.nvim_buf_set_lines(handle.buf, -1, -1, false, { text_of(entry) })
        end

        vim.bo[handle.buf].modifiable = false

        if handle.win and vim.api.nvim_win_is_valid(handle.win) then
            vim.api.nvim_win_set_cursor(handle.win, { at, 0 })
        end
    end)
end

-- Held partials are flushed as plain lines when the operation ends: a
-- stream that dies mid-line still leaves its last words readable.
local function flush(handle)
    for _, st in pairs(handle.streams) do
        if st.since ~= "" then
            append(handle, { kind = "out", text = st.since })
            st.since = ""
        end
    end
end

local function freeze(handle)
    local entry = handle.lines[handle.phase_at]

    if entry and not entry.frozen then
        entry.frozen = now()
        render_line(handle, handle.phase_at)
    end
end

-- Both outcomes end the operation: flush any held tail and freeze the clock.
local function wind_down(handle)
    flush(handle)
    freeze(handle)
    stop_clock(handle)
end

local function tick(handle)
    if handle.dead or not alive(handle) then
        stop_clock(handle)
        return
    end

    local entry = handle.phase_at and handle.lines[handle.phase_at]

    if not entry or entry.frozen then
        return
    end

    render_line(handle, handle.phase_at)
end

-- \r rewrites the stream's live line in place, \n commits it, and bytes
-- without a terminator are held; each stream keeps its own line, so
-- stderr can never merge into a half-written progress line.
local function commit(handle, source, seg, newline)
    local st = handle.streams[source]
    local at = st.live

    if newline then
        if at then
            if seg ~= "" then
                handle.lines[at].text = seg
            end

            handle.lines[at].kind = "out"
            st.live = nil
            render_line(handle, at)
        else
            append(handle, { kind = "out", text = seg })
        end

        return
    end

    if seg == "" then
        return
    end

    if at then
        handle.lines[at].text = seg
        render_line(handle, at)
    else
        append(handle, { kind = "out", text = seg })
        st.live = #handle.lines
    end
end

local function feed(handle, source, chunk)
    if not alive(handle) or not chunk then
        return
    end

    if not handle.streams[source] then
        source = "stdout"
    end

    local st = handle.streams[source]
    local rest = st.since .. chunk

    st.since = ""

    while #rest > 0 do
        local cr = rest:find "\r"
        local nl = rest:find "\n"
        local at = cr and (not nl or cr < nl) and cr or nl

        if not at then
            st.since = rest
            return
        end

        local seg = rest:sub(1, at - 1)
        local newline = rest:sub(at, at) == "\n"

        rest = rest:sub(at + 1)
        commit(handle, source, seg, newline)
    end
end

-- The per-operation handle. The window materializes only on handle:open -
-- announcing phases and streaming output never opens it on their own.
function M.create()
    if #vim.api.nvim_list_uis() == 0 then
        return M.null()
    end

    local buf = vim.api.nvim_create_buf(false, true)

    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].modifiable = false

    local handle

    vim.keymap.set("n", "q", function()
        if handle.win and vim.api.nvim_win_is_valid(handle.win) then
            pcall(vim.api.nvim_win_close, handle.win, true)
        end
    end, { buffer = buf, nowait = true, silent = true })

    handle = {
        buf = buf,
        lines = {},
        streams = { stdout = { since = "" }, stderr = { since = "" } },
        phase_at = nil,
        timer = nil,
        opened = false,
        win = nil,
        dead = false,

        phase = function(_, text)
            if not alive(handle) then
                return
            end

            freeze(handle)
            append(handle, { kind = "phase", text = text, started = now() })
            handle.phase_at = #handle.lines

            if not handle.timer then
                handle.timer = vim.uv.new_timer()
                handle.timer:start(CLOCK_PERIOD, CLOCK_PERIOD, function()
                    vim.schedule(function()
                        tick(handle)
                    end)
                end)
            end
        end,

        open = function(_)
            if handle.opened then
                return handle.win
            end

            if not alive(handle) then
                return nil
            end

            local ok, win = pcall(vim.api.nvim_open_win, buf, false, {
                split = "below",
                win = vim.api.nvim_get_current_win(),
                height = math.min(WIN_HEIGHT, math.max(vim.o.lines - 2, 1)),
            })

            if not ok then
                handle.dead = true
                return nil
            end

            handle.opened = true
            handle.win = win

            pcall(function()
                local rendered = {}

                for i, entry in ipairs(handle.lines) do
                    rendered[i] = text_of(entry)
                end

                vim.bo[buf].modifiable = true
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, rendered)
                vim.bo[buf].modifiable = false
                vim.api.nvim_win_set_cursor(win, { math.max(#rendered, 1), 0 })
            end)

            return win
        end,

        stream = function(_, chunk, source)
            feed(handle, source or "stdout", chunk)
        end,

        succeed = function(_)
            wind_down(handle)

            if handle.win and vim.api.nvim_win_is_valid(handle.win) then
                pcall(vim.api.nvim_win_close, handle.win, true)
            elseif alive(handle) then
                pcall(vim.api.nvim_buf_delete, buf, { force = true })
            end

            handle.dead = true
        end,

        fail = function(_)
            wind_down(handle)

            if handle.win and vim.api.nvim_win_is_valid(handle.win) then
                pcall(vim.api.nvim_set_current_win, handle.win)
                return
            end

            if not handle.opened and alive(handle) then
                pcall(vim.api.nvim_buf_delete, buf, { force = true })
            end

            handle.dead = true
        end,
    }

    return handle
end

return M
