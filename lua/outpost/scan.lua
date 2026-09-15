-- Remote run/ enumeration: the outpost's run/ directory is ground truth
-- for what sessions actually exist on it. Shared by `list`'s scan and
-- `down`'s pre-confirm session count.

local transport = require "outpost.transport"

local M = {}

-- List each session id under run/ next to its manifest contents (or
-- nothing, tab-separated), one per line.
function M.build_scan_command()
    return [[
set -eu
RUN="$HOME/.cache/outpost/run"
[ -d "$RUN" ] || exit 0
for dir in "$RUN"/*/; do
    [ -d "$dir" ] || continue
    id="$(basename "$dir")"
    manifest="$dir/manifest.json"
    if [ -f "$manifest" ]; then
        printf '%s\t%s\n' "$id" "$(cat "$manifest")"
    else
        printf '%s\t\n' "$id"
    fi
done
]]
end

-- Parse the scan command's output into a list of
-- { session_id, canonical_path, endpoint, created }. A session id with no
-- manifest, or an unreadable one, is still included with the identity
-- fields nil - run/ is ground truth about existence, not identity.
function M.parse(output)
    local entries = {}

    for line in (output or ""):gmatch "[^\n]+" do
        local session_id, manifest_json = line:match "^(%S+)\t(.*)$"

        if session_id then
            local entry = { session_id = session_id }

            if manifest_json ~= "" then
                local ok, manifest = pcall(vim.json.decode, manifest_json)

                if ok and type(manifest) == "table" then
                    entry.canonical_path = manifest.canonical_path
                    entry.endpoint = manifest.endpoint
                    entry.created = manifest.created
                end
            end

            table.insert(entries, entry)
        end
    end

    return entries
end

-- Scan one host's run/ directory. callback(entries, err).
function M.host(endpoint, conn, callback)
    transport.run(endpoint, M.build_scan_command(), conn, function(code, out, err)
        if code ~= 0 then
            callback(nil, err or ("scan failed with exit " .. code))
            return
        end

        callback(M.parse(out), nil)
    end)
end

return M
