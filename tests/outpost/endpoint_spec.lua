-- Unit spec for endpoint expansion (offline by construction).

local endpoint = require "outpost.endpoint"

describe("endpoint expansion", function()
    -- Recorded from `ssh -G fixturebox` against a config declaring
    -- HostName 127.0.0.1 / Port 2222 / User dev.
    local recorded = table.concat({
        "user dev",
        "hostname 127.0.0.1",
        "port 2222",
    }, "\n")

    it("builds the endpoint from the resolved user and hostname", function()
        assert.equal("dev@127.0.0.1", endpoint.from_ssh_g(recorded))
    end)

    it("ignores the recorded port - endpoints carry no port", function()
        local endpoint_str = endpoint.from_ssh_g(recorded)

        assert.falsy(endpoint_str:find "2222")
    end)

    it("reads values among the full ssh -G field set", function()
        -- `ssh -G` emits many fields; user/hostname are not adjacent.
        local full = table.concat({
            "user dev",
            "hostkeyalias none",
            "hostname 127.0.0.1",
            "port 2222",
            "addressfamily any",
        }, "\n")

        assert.equal("dev@127.0.0.1", endpoint.from_ssh_g(full))
    end)

    it("keeps the resolved user, not a typed one", function()
        local full = "user other\nhostname remote.example.com\nport 22\n"

        assert.equal("other@remote.example.com", endpoint.from_ssh_g(full))
    end)
end)
