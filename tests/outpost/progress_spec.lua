-- Unit spec for the progress view (offline, headless): the \r-aware line
-- rewriting, the phase clocks, and the open/succeed/fail/user-close lifecycle.

local progress = require "outpost.progress"

local stub = require "luassert.stub"

-- The real window machinery needs a UI to exist; headless nvim reports
-- none. Each window-owning describe pretends one until it is done.
local function pretend_ui()
    return stub(vim.api, "nvim_list_uis").returns { { focusable = true } }
end

local function window_count()
    return #vim.api.nvim_list_wins()
end

describe("progress handle window", function()
    local ui
    local handle

    before_each(function()
        ui = pretend_ui()
        handle = progress.create()
    end)

    after_each(function()
        if handle then
            handle:succeed()
        end

        ui:revert()
    end)

    it("opens a bottom-split read-only window on demand", function()
        local win = handle:open()

        assert.truthy(win and vim.api.nvim_win_is_valid(win))
        assert.equal("below", vim.api.nvim_win_get_config(win).split)
        assert.equal(handle.buf, vim.api.nvim_win_get_buf(win))
        assert.equal(false, vim.bo[handle.buf].modifiable)
    end)

    it("opens at most one window per handle", function()
        local before = window_count()
        local first = handle:open()

        assert.equal(first, handle:open())
        assert.equal(before + 1, window_count())
    end)

    it("opens nothing before on demand - announcing phases alone is free", function()
        local before = window_count()

        handle:phase "probing the outpost"

        assert.equal(before, window_count())

        handle:open()

        assert.equal(before + 1, window_count())
    end)

    it("renders phase lines as they are announced", function()
        handle:open()
        handle:phase "probing the outpost"
        handle:phase "syncing the config tree"

        local lines = vim.api.nvim_buf_get_lines(handle.buf, 0, -1, false)

        assert.truthy(lines[1]:find("probing the outpost", 1, true))
        assert.truthy(lines[2]:find("syncing the config tree", 1, true))
    end)

    it("carries an elapsed clock on the current phase line, frozen when the phase ends", function()
        handle:open()
        handle:phase "probing the outpost"

        local lines = vim.api.nvim_buf_get_lines(handle.buf, 0, -1, false)

        assert.truthy(lines[1]:find("probing the outpost (0s)", 1, true))

        assert.truthy(
            vim.wait(3000, function()
                local now_lines = vim.api.nvim_buf_get_lines(handle.buf, 0, -1, false)
                local elapsed = now_lines[1]:match "%((%d+)s%)"

                return elapsed and tonumber(elapsed) >= 1
            end),
            "the phase clock never ticked"
        )

        handle:phase "syncing the config tree"

        local frozen = vim.api.nvim_buf_get_lines(handle.buf, 0, -1, false)

        assert.truthy(frozen[1]:match "%((%d+)s%)", "the ended phase's clock is frozen in place")
        assert.truthy(frozen[2]:find("syncing the config tree (0s)", 1, true))
    end)

    it("rewrites the carriage-return-carried progress line in place", function()
        handle:open()
        handle:phase "syncing the config tree"

        -- the shape rsync emits: each update carried behind a \r
        handle:stream "\r        1,024   0%    0.00kB/s    0:00:00\r"
        handle:stream "\r        2,048   1%    9.54MB/s    0:00:00\r"

        local lines = vim.api.nvim_buf_get_lines(handle.buf, 0, -1, false)

        assert.equal(2, #lines, "each update must rewrite, never append")
        assert.truthy(lines[2]:find("2,048   1%", 1, true))
    end)

    it("commits the progress line at the newline and appends the stats block after it", function()
        handle:open()
        handle:stream "\r        2,048   1%    9.54MB/s    0:00:00\n"
        handle:stream "Number of files: 5 (reg: 3, dir: 2)\n"
        handle:stream "Total transferred file size: 2,048 bytes\n"

        local lines = vim.api.nvim_buf_get_lines(handle.buf, 0, -1, false)

        assert.are.same({
            "        2,048   1%    9.54MB/s    0:00:00",
            "Number of files: 5 (reg: 3, dir: 2)",
            "Total transferred file size: 2,048 bytes",
        }, lines)
    end)

    it("holds a partial chunk, never rendering a mid-line", function()
        handle:open()
        handle:phase "syncing the config tree"

        handle:stream "\r        2,048   1%"

        assert.equal(1, #vim.api.nvim_buf_get_lines(handle.buf, 0, -1, false), "the partial is held")

        handle:stream "    9.54MB/s    0:00:00\r"

        local lines = vim.api.nvim_buf_get_lines(handle.buf, 0, -1, false)

        assert.equal(2, #lines)
        assert.truthy(lines[2]:find("2,048   1%    9.54MB/s    0:00:00", 1, true))
    end)

    it("renders a whole rsync progress2 run as one rewritten line plus the stats", function()
        handle:open()
        handle:phase "syncing the config tree"

        -- the shape rsync actually emits: \r-terminated updates, a final
        -- \n-terminated one, then the stats block
        handle:stream "\r        1,024   0%    0.00kB/s    0:00:00\r        2,048   1%    9.54MB/s    0:00:00\r"
        handle:stream "        4,096   2%   19.07MB/s    0:00:00\n"
        handle:stream "Number of regular files transferred: 3\n"

        local lines = vim.api.nvim_buf_get_lines(handle.buf, 0, -1, false)

        assert.equal(3, #lines)
        assert.truthy(lines[2]:find("4,096   2%   19.07MB/s", 1, true))
        assert.truthy(lines[3]:find("Number of regular files transferred", 1, true))
    end)

    it("rewrites curl's byte meter the same way, below its header lines", function()
        handle:open()
        handle:phase "downloading the bundle"

        handle:stream("  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current\n", "stderr")
        handle:stream("                                 Dload  Upload   Total   Spent    Left  Speed\n", "stderr")
        handle:stream("  0      0    0     0    0     0      0      0 --:--:-- --:--:-- --:--:--     0\r", "stderr")
        handle:stream(" 12 40.0M   12 5120k    0     0   1.2M      0  0:00:33  0:00:04  0:00:29  1.3M\r", "stderr")

        local lines = vim.api.nvim_buf_get_lines(handle.buf, 0, -1, false)

        assert.equal(4, #lines)
        assert.truthy(lines[4]:find("12 5120k", 1, true))
    end)

    it("keeps stderr lines out of a half-written stdout line", function()
        handle:open()

        handle:stream "\r        2,048   1%"
        handle:stream("rsync: [sender] read error: connection dropped\n", "stderr")
        handle:stream "    9.54MB/s    0:00:00\n"

        local lines = vim.api.nvim_buf_get_lines(handle.buf, 0, -1, false)

        -- each stream owns its own line: nothing merged, nothing erased
        assert.equal(2, #lines)
        assert.equal("rsync: [sender] read error: connection dropped", lines[1])
        assert.equal("        2,048   1%    9.54MB/s    0:00:00", lines[2])
    end)

    it("appends newline-carried output line by line", function()
        handle:open()
        handle:stream "sent 234 bytes  received 56 bytes\n"
        handle:stream "total size is 2,048  speedup is 0.99\n"

        assert.are.same(
            { "sent 234 bytes  received 56 bytes", "total size is 2,048  speedup is 0.99" },
            vim.api.nvim_buf_get_lines(handle.buf, 0, -1, false)
        )
    end)

    it("auto-closes the window on success", function()
        local win = handle:open()

        handle:succeed()

        assert.falsy(win and vim.api.nvim_win_is_valid(win))
        assert.falsy(vim.api.nvim_buf_is_valid(handle.buf))
    end)

    it("keeps the view open and takes focus on failure", function()
        local before = vim.api.nvim_get_current_win()
        local win = handle:open()

        handle:fail()

        assert.truthy(win and vim.api.nvim_win_is_valid(win))
        assert.equal(win, vim.api.nvim_get_current_win())

        vim.api.nvim_set_current_win(before)
    end)

    it("never errors when the user closes the view mid-operation", function()
        local before = window_count()
        local win = handle:open()

        vim.api.nvim_win_close(win, true)

        handle:phase "syncing the data tree"
        handle:stream "\r        9,216   5%    9.54MB/s    0:00:00\n"
        handle:stream("late error\n", "stderr")

        -- the clock stops itself once the view is gone, even mid-operation
        assert.truthy(
            vim.wait(2500, function()
                return handle.timer == nil
            end),
            "the elapsed clock must not outlive the view"
        )

        handle:succeed()
        handle:fail()

        assert.equal(before, window_count(), "no window may reappear")
    end)

    it("never errors, and reopens nothing, when the operation ends after the user closed the view", function()
        local win = handle:open()

        vim.api.nvim_win_close(win, true)

        handle:succeed()

        assert.falsy(vim.api.nvim_win_is_valid(win))
    end)

    it("renders the phases announced before the window existed", function()
        handle:phase "probing the outpost"
        handle:phase "syncing the config tree"

        handle:open()

        local lines = vim.api.nvim_buf_get_lines(handle.buf, 0, -1, false)

        assert.equal(2, #lines)
        assert.truthy(lines[1]:find("probing the outpost", 1, true))
        assert.truthy(lines[2]:find("syncing the config tree", 1, true))
    end)

    it("dismisses on 'q' like every other read-only surface", function()
        local win = handle:open()

        vim.api.nvim_set_current_win(win)
        vim.api.nvim_feedkeys("q", "x", false)

        assert.truthy(
            vim.wait(1000, function()
                return not vim.api.nvim_win_is_valid(win)
            end),
            "the view must dismiss on 'q'"
        )
    end)
end)

describe("progress handle in headless nvim", function()
    it("degrades to a null handle: no window, no buffer, no error", function()
        local wins_before = #vim.api.nvim_list_wins()
        local bufs_before = #vim.api.nvim_list_bufs()

        local handle = progress.create()

        handle:phase "probing the outpost"
        handle:open()
        handle:stream "\r        1,024   0%    0.00kB/s    0:00:00"
        handle:stream("boom\n", "stderr")
        handle:fail()
        handle:succeed()

        assert.equal(wins_before, #vim.api.nvim_list_wins())
        assert.equal(bufs_before, #vim.api.nvim_list_bufs())
    end)
end)

describe("the setup opt-out", function()
    local config = require "outpost.config"

    after_each(function()
        config.setup {}
    end)

    it("hands every surface a null handle when setup disabled the view", function()
        config.setup { progress = false }

        local ui = pretend_ui()

        local wins_before = #vim.api.nvim_list_wins()
        local bufs_before = #vim.api.nvim_list_bufs()

        local handle = progress.create()

        handle:phase "probing the outpost"

        assert.equal(wins_before, #vim.api.nvim_list_wins(), "announcing phases opens nothing")
        assert.falsy(handle:open(), "the disabled factory must hand back a handle that opens no window")
        assert.equal(wins_before, #vim.api.nvim_list_wins())

        handle:stream "\r        1,024   0%    0.00kB/s    0:00:00"
        handle:stream("boom\n", "stderr")
        handle:fail()
        handle:succeed()

        assert.equal(wins_before, #vim.api.nvim_list_wins())
        assert.equal(bufs_before, #vim.api.nvim_list_bufs())

        ui:revert()
    end)

    it("creates a real window again once the view is re-enabled", function()
        config.setup { progress = false }
        config.setup {}

        local ui = pretend_ui()
        local handle = progress.create()
        local win = handle:open()

        assert.truthy(win and vim.api.nvim_win_is_valid(win))

        handle:succeed()
        ui:revert()
    end)
end)

describe("elapsed formatting", function()
    it("counts seconds inside the first minute", function()
        assert.equal("0s", progress.format_elapsed(0))
        assert.equal("59s", progress.format_elapsed(59.4))
    end)

    it("switches to a clock face beyond the minute", function()
        assert.equal("1:00", progress.format_elapsed(60))
        assert.equal("2:05", progress.format_elapsed(125))
    end)
end)

describe("size formatting", function()
    it("formats sizes for humans", function()
        assert.equal("512 bytes", progress.format_size(512))
        assert.equal("2.0 KiB", progress.format_size(2048))
        assert.equal("3.0 MiB", progress.format_size(3 * 1048576))
    end)
end)
