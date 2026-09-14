# Tests

| Command | What it does |
| --- | --- |
| `make test` | Unit specs only. |
| `make test-integration` | Boots the docker sshd fixture, runs **all** specs (unit + integration) against it, tears it down. |
| `make harness-up` / `harness-down` | Start/stop the fixture alone (e.g. while iterating on integration specs). |
| `make harness-logs` / `harness-shell` | Inspect the fixture: sshd logs, or an interactive shell into it. |

## Layout

```
tests/
├── minimal_init.lua        <- headless bootstrap: clones plenary, wires rtp
├── README.md
└── outpost/
    ├── Dockerfile          <- disposable alpine sshd fixture
    ├── entrypoint.sh       <- stateless boot (host keys regenerated each run)
    ├── await.lua           <- sync-spec helper: pumps async callbacks via vim.wait
    ├── harness.lua         <- connection details + ssh/scp option assembly
    ├── harness_spec.lua    <- the harness's own tests (unit + integration)
    ├── transport_spec.lua  <- option assembly (unit) + execution (integration)
    ├── release_spec.lua    <- pipeline pure helpers (unit)
    ├── dispatch_spec.lua   <- user command surface (unit)
    ├── update_flow_spec.lua <- release pipeline end-to-end (integration + internet)
    └── .keys/              <- fixture keypair + known_hosts
```

## The fixture

The harness is a **disposable alpine sshd container standing in for a remote
host** - key auth only, bound to `127.0.0.1:2222`, fresh host keys on every
`harness-up` (with a fresh `known_hosts` to match). It exists so the full
product flow - provisioning, sessions, tunnels, attach - is testable locally
with zero real remotes and zero runner time.

Integration specs connect as `outpost@127.0.0.1:2222` using the keypair in
`.keys/`. Every fixture-dependent spec must start with:

```lua
if not harness.pending_unless_up() then
    return
end
```

so the spec stays **pending, not failing**, when the fixture is not running.
This keeps `make test` green on any machine without docker.

`update_flow_spec.lua` additionally needs **internet**: it drives the real
release pipeline (resolve the latest tag, download the ~13 MB bundle on
base, checksum-verify, transfer over ssh, extract, record the version),
which is the point of the test. Its local download cache is injected
(fresh temp dir per run), so the user's real cache is untouched.

## Environment

The Makefile exports these for integration runs; `harness.lua` defaults
match them:

| Variable | Default |
| --- | --- |
| `OUTPOST_TEST_HOST` | `127.0.0.1` |
| `OUTPOST_TEST_PORT` | `2222` |
| `OUTPOST_TEST_USER` | `outpost` |
| `OUTPOST_TEST_KEY` | `tests/outpost/.keys/id_ed25519` |
| `OUTPOST_TEST_KNOWN_HOSTS` | `tests/outpost/.keys/known_hosts` |

## Conventions

- Unit specs are pure logic (parsing, hashing, registry, templates) and must
  never reach the network. If a unit spec wants to touch the fixture, it is
  an integration spec - mark it with the `pending_unless_up` gate.
- Helper modules live in `tests/outpost/` and are required as
  `"outpost.<name>"` (the plugin's own `lua/outpost/` tree takes precedence
  on name collisions by construction).
