-- Await an async callback-style function from a synchronous spec.
--   local ok, err = unpack(await(release.install, 180000, host, platform, tag, opts))

return function(fn, timeout, ...)
    local done = false
    local results = {}

    local args = { ... }
    table.insert(args, function(...)
        results = { ... }
        done = true
    end)

    fn(unpack(args))

    assert.truthy(
        vim.wait(timeout or 10000, function()
            return done
        end),
        "timed out waiting for async result"
    )

    return results
end
