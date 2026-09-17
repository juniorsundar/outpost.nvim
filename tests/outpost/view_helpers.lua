-- Shared spec helpers: the recording progress handle and the stub/window
-- idioms the command-surface specs share.

local stub = require "luassert.stub"

local M = {}

-- The window machinery needs a UI to exist; headless nvim reports none.
function M.pretend_ui()
    return stub(vim.api, "nvim_list_uis").returns { { focusable = true } }
end

-- One stubbed module field, registered on the caller's revert list.
function M.replace(stubs, module, name, impl)
    local s = stub(module, name)

    s.invokes(impl)
    table.insert(stubs, s)

    return s
end

-- A recording handle: every view interaction lands in one ordered event
-- list (collaborator call markers included), with outcome counters beside
-- them for the integration specs.
function M.recording_view()
    local events = {}

    local handle = {
        events = events,
        phases = {},
        chunks = {},
        opened = 0,
        succeeded = false,
        failed = false,
    }

    function handle:phase(text)
        table.insert(events, { kind = "phase", text = text })
        table.insert(self.phases, text)
    end

    function handle:open()
        table.insert(events, { kind = "open" })
        self.opened = self.opened + 1
    end

    function handle:stream(chunk, source)
        table.insert(events, { kind = "stream", chunk = chunk, source = source })
        table.insert(self.chunks, { chunk = chunk, source = source })
    end

    function handle:succeed()
        table.insert(events, { kind = "succeed" })
        self.succeeded = true
    end

    function handle:fail()
        table.insert(events, { kind = "fail" })
        self.failed = true
    end

    -- The stream payload as one string, for find-based output assertions.
    function handle:streamed()
        local joined = {}

        for _, entry in ipairs(self.chunks) do
            table.insert(joined, entry.chunk)
        end

        return table.concat(joined)
    end

    return handle
end

-- The event names in order: phases prefixed, collaborator calls by name.
function M.timeline(view)
    local names = {}

    for _, event in ipairs(view.events) do
        if event.kind == "phase" then
            table.insert(names, "phase: " .. event.text)
        elseif event.kind == "call" then
            table.insert(names, event.name)
        else
            table.insert(names, event.kind)
        end
    end

    return names
end

-- Whether the handle ever materialized its window.
function M.opened(view)
    return view.opened > 0
end

-- The ids of every open window right now.
function M.window_set()
    local set = {}

    for _, win in ipairs(vim.api.nvim_list_wins()) do
        set[win] = true
    end

    return set
end

-- The window that appeared beyond a baseline window set: the view's own.
function M.new_window(baseline)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if not baseline[win] then
            return win
        end
    end

    return nil
end

return M
