# Tests

| Command | What it does |
| --- | --- |
| `make test` | Unit specs; integration cases stay pending without probing SSH. |
| `make test-integration` | Prepare/reuse the release fixture, boot docker sshd, run all specs sequentially, tear down even on failure. |
| `make test-fixture` | Fetch the latest bundle once; subsequent calls verify the cached checksum locally. |
| `make test-fixture-refresh` | Explicitly resolve latest again and fetch/verify the bundle. |
| `make test-release` | Opt-in live GitHub test: fresh download, checksum, SSH transfer and installation (`update_flow_spec.lua` only). |
| `make harness-up` / `harness-down` | Start/stop the disposable sshd fixture for iteration. |
| `make harness-logs` / `harness-shell` | Inspect the fixture. |

## Release cache

The test-only cache defaults to `~/.cache/outpost-tests` (`TEST_CACHE=/absolute/path`
for make, `OUTPOST_TEST_CACHE` for direct nvim invocations). It is separate from
the plugin's real download cache:

- `tag` pins the prepared release until explicitly refreshed.
- `releases/<tag>/` holds the published archive and checksum for the local
  platform (the native Docker fixture uses the same architecture).

A cold preparation makes one latest-release API request and fetches the
archive and checksum. Warm runs make **no GitHub release requests**. A corrupt
fixture fails with a refresh instruction rather than silently using the
network. Do not point a spec's download destination at `releases/<tag>/`:
that directory is the read-only source, not a working cache.

Routine integration specs replace only release discovery and asset URLs:
`latest_tag` returns the prepared pin, and asset URLs point to local `file://`
URLs. The real curl copy, checksum validation, SSH transfer, extraction,
sessions, and pinned-client logic still run. Fresh-cache assertions remain
fresh; no install/session checks are skipped. `make test-release` bypasses
these substitutions to check the live GitHub contract.

CI persists this cache with `actions/cache`. To refresh CI's pin, delete its
`outpost-release-v1-*` Actions cache (or bump the cache key). Refresh locally
with `make test-fixture-refresh`.

Initial Plenary bootstrap and Docker image builds can still need internet;
release caching does not make those external dependencies offline.

## Iteration

Run one file instead of the whole suite:

```sh
make test TESTS_DIR=tests/outpost/release_fixture_spec.lua
make test-integration TESTS_DIR=tests/outpost/up_session_spec.lua
```

To keep the container running between specs:

```sh
make test-fixture harness-up
OUTPOST_TEST_INTEGRATION=1 nvim --headless --noplugin -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/outpost/up_session_spec.lua")'
make harness-down
```

The full integration suite stays sequential: specs share one disposable
remote account and some deliberately destroy its installation. Do not run
multiple integration suites against that account or refresh its release
cache concurrently.

## Fixture and environment

The Alpine sshd container binds to `127.0.0.1:2222`. `outpost` uses the
fixture key; `outpass` tests password authentication through the askpass
bridge. Host keys and `known_hosts` are renewed on each `harness-up`.

The Makefile exports these; direct invocations use the same defaults:

| Variable | Default |
| --- | --- |
| `OUTPOST_TEST_INTEGRATION` | disabled; set `1` to enable fixture tests |
| `OUTPOST_TEST_LIVE_RELEASE` | disabled; set `1` to bypass the local release mirror |
| `OUTPOST_TEST_CACHE` | `~/.cache/outpost-tests` |
| `OUTPOST_TEST_HOST` | `127.0.0.1` |
| `OUTPOST_TEST_PORT` | `2222` |
| `OUTPOST_TEST_USER` | `outpost` |
| `OUTPOST_TEST_PASS_USER` | `outpass` |
| `OUTPOST_TEST_PASSWORD` | `fixture-password` |
| `OUTPOST_TEST_KEY` | `tests/outpost/.keys/id_ed25519` |
| `OUTPOST_TEST_KNOWN_HOSTS` | `tests/outpost/.keys/known_hosts` |

## Conventions

- Specs are Plenary-busted under `tests/outpost/`. Helpers there are required
  as `outpost.<name>` via `tests/minimal_init.lua`.
- Every fixture-dependent case starts with
  `if not harness.pending_unless_up() then return end`. Disabled integration
  cases stay pending; explicitly enabled integration fails if SSH is unavailable.
- The harness probes once per spec process and reuses SSH multiplexing for
  its state assertions, rather than authenticating for every shell command.
- Prefer bounded waits on completion signals over fixed sleeps. Unit tests
  control time explicitly when testing timestamps.
