# Outpost - Design

Outpost is a vscode-server-like remote development layer for Neovim:
provision a portable, musl-bundled Neovim on a remote host, run a persistent
headless project session there, and attach a local `--remote-ui` client to it
from a separate terminal.

## Terminology and authority model

Four named entities - this vocabulary is normative for all other docs:

| Entity | What it is | Lifetime | Scope of |
| --- | --- | --- | --- |
| **base** | The local machine: credentials, config/plugin source of truth, the plugin (control plane), attaching clients | as long as the user lives there | `sync`, `update` (issuing), all lifecycle commands |
| **outpost** | The installation under **one remote account**: portable nvim install, synced config/plugins, session sockets - everything under `~/.cache/outpost/` | until `down`; disposable by design (cattle) | `up`, `down`, `update`, `sync` (receiving) |
| **session** | One headless nvim server inside an outpost, bound to a project directory; owns editing state (buffers, LSP, terminals) | until `stop` or host death - *state is declared lossy by policy* | `stop`, and the attach target |
| **project** | A directory on the remote. Pre-existing user data, **never owned by outpost** | not ours | nothing - outpost points at it, `stop` never touches it |

Rules:

1. The base is the only authority. Outposts/sessions never act autonomously
   (no self-update, no remote cron, no systemd units).
2. Material flows one way: config/plugins sync base → outpost, never back.
3. Outposts are disposable - reproducible from (upstream release + base sync).
   Destroying one loses nothing but session state.
4. Session state is the only non-reproducible thing, and is *lossy by policy*:
   a remote reboot or `stop` kills it, and that is by design, not a bug.
5. Credentials are forwarded (ssh-agent), never stored on the outpost.
6. Discovery scans the remote (`run/` directory is ground truth for sessions);
   the local registry is a cache/enrichment layer, reconciled on every `list`
   by every base. No base trusts its own registry over the remote.
7. Outposts may live on **shared hosts**: everything under `run/` is private
   (`umask 077` when creating dirs; socket mode 0600). A reachable session
   socket is code-execution-as-the-user.
8. **Outposts are airgap-friendly.** The remote needs nothing but an ssh
   daemon reachable from base. All internet downloads happen on base and
   transfer over ssh (portable nvim, zig, anything else). A feature needing
   anything on the remote means the outpost bundle ships it - the host's
   own tooling is never a dependency. **This guarantee covers what the
   plugin itself does**, nothing more: what the synced user config does
   (plugin-manager bootstraps, plugin network calls) is the user's
   program and the user's headache, never something outpost guards
   against.

## Core model

- **The plugin is a control plane.** It runs inside a *local* nvim and
  manages outposts. It does not own tunnels or attached clients.
- **Attach is external and self-contained.** `up` hands the user an attach
  script; the script owns its tunnel + attaching client lifecycle and works
  whether or not the launching nvim is still open.
- **Sessions persist across attaches.** Detaching leaves the remote server
  running. Only `stop` (session) or `down` (outpost) destroys things.
- **`up` always takes over.** UI client liveness is undecidable (UI channels
  are notify-only; a dropped TCP connection without FIN can hold the UI slot
  for hours because sshd does no liveness probing by default). Therefore
  `up` detaches any attached UI (`chanclose` on the UI channel) before
  handing out the attach command. There is no refuse path.
- **The attach client is pinned for parity.** The attach script execs an
  outpost-builds nvim of the *same release tag* as the remote install,
  downloaded to the local cache at `up` time (~12 MB once per tag).
  `OUTPOST_NVIM` overrides the binary for development.
- **Always latest stable** is the version policy on both ends: outpost-builds
  mirrors upstream stable releases; local nix/distro nvim is assumed near it.

## Session identity

- The typed target (`user@host:path`; host may be an ssh alias) expands
  locally via `ssh -G` into the **endpoint** (`user@hostname`) - transport
  only, never part of identity.
- Each outpost mints an **instance id** (UUID) at install time:
  `~/.cache/outpost/instance-id`. Two accounts on one machine are two
  outposts with separate instance ids.
- The project path is canonicalized with `realpath` **on the remote**
  (trailing slashes, relative segments, and symlinks must not fork identity).
- `session id = sha256(instance_id + ":" + canonical_path)[:6]`.
- A nonexistent project directory is an error (no auto-creation).
- Sessions live at `~/.cache/outpost/run/<session-id>/` - socket, log, and a
  **manifest** recording the canonical path and last-known endpoint (the
  remote scan's source of truth).
- The outpost-wide portable install (shared by sessions) is
  `~/.cache/outpost/install/current` + `install/version` (release tag).
- Endpoint churn (hostname, IP, alias) never forks identity; identity does
  not survive `down` (the instance id dies with the installation).
- Remote servers start in the **outpost's XDG home**: the start
  script captures the account's original XDG vars (set or unset) as
  `OUTPOST_ORIG_XDG_*`, then exports
  `XDG_{CONFIG,DATA,STATE,CACHE}_HOME` into
  `~/.cache/outpost/{config,data,state,cache}` and forces
  `NVIM_APPNAME=nvim`, so the server's stdpaths - and sync's targets -
  live inside the outpost and can never collide with a native nvim on the
  account.
- **Children of a session see the account's normal environment:** nvim
  computes its stdpaths at startup, so the start script restores the
  captured originals (unsetting any that were originally unset) and
  unsets `OUTPOST_SESSION` via a `--cmd` Lua fragment - before user
  config, after startup. Terminals and jobs inside a session behave like
  normal host processes (`gh`, git XDG config, etc.); a native nvim
  launched in a session terminal does not branch as a session.
- The plugin runs in **session mode** inside outposts: under
  `OUTPOST_SESSION`, `init.lua` registers nothing and `setup()` ships
  only the OSC52 **session branch** (opt-out via `setup`) - the control
  plane never runs on an outpost (rule 1 as a code-level guarantee, not
  a documentation hope).

## Command surface

Single command, subcommand dispatch: `:Outpost <subcommand> [args]`
(`:Outpost! <subcommand>` = no-confirmation variant where applicable).

Targets: any command taking a target accepts either form - `<session id>`
(short, from `list`) or `<user@host>:<path>` - with completion always showing both
(`ab12cd  devbox:~/code/neovim (live)`). Neither form is primary. The two
forms resolve differently, though: the long form always re-runs the
identity ladder (`ssh -G` → remote probe/realpath → session id), so it works
even for a session this base has never registered; the short form only
ever resolves via a **registry lookup** (session ids are not computable
offline) - a miss is a clear error pointing at `:Outpost list`, never a
fallback scan.

Destructive commands (`stop`, `down`) confirm via a `vim.ui.select` yes/no
prompt unless banged (`:Outpost! stop`, `:Outpost! down` skip it). `list`'s
bang means something different - see below.

### `:Outpost up [target]`

Bare `up` opens a `vim.ui.select` picker over live sessions, registry
entries, and ssh-config hosts - no path required up front.

With a target:

1. Resolve the endpoint locally (`ssh -G`); if it resolves to the base
   itself (same user@hostname), error - an outpost on the base machine is
   not supported, and `sync`/`update`/`down` inherit the refusal through
   the same resolution step. Over ssh, fetch/mint the outpost instance id
   and canonicalize the project path (`realpath`); compute the session id;
   check the registry.
2. Healthy session already exists → skip to 6 (idempotent).
3. Otherwise provision: ensure the portable install (resolve
   `outpost-builds` latest release, download, checksum, scp, extract);
   run the provisioning sync when the install just happened or the sync
   marker (`~/.cache/outpost/synced`) is missing - a failed sync aborts
   `up` before any session starts; then start a headless
   server with cwd = canonical project path, `umask 077`,
   `OUTPOST_SESSION=1`, the relocated XDG environment.
4. Register the session in the local registry.
5. Take over: `chanclose()` every attached UI; notify "detached existing
   UI".
6. Present the attach command: a floating window with the generated attach
   script (`<stdpath cache>/outpost/attach/<session-id>.sh`), auto-yanked into the `"`
   and `+` registers; `q` dismisses (every other key passes through, so the
   command can still be yanked with `y`/`yy` before dismissing). The script
   opens its own `ssh -L` tunnel, execs the pinned local outpost-builds
   client with `--remote-ui`, and tears the tunnel down on exit
   (best-effort `trap`).

### `:Outpost list [host]`

- Read-only report - no picker, no confirm, nothing else offered from here
  (management lives in `stop`/`down`'s own pickers, not in `list`).
- With no argument, scan every known host (registry ∪ ssh config); with a
  `host` argument, scope the scan to that one host only (skips the round
  trips to the rest).
- Per host: list `~/.cache/outpost/run/` - the remote is ground truth; adopt
  sessions unknown to the local registry. Probe each found session
  (parallel, timeout-bounded) for liveness.
- Render the report in a floating window (reusing `present.lua`'s `q`-to-
  dismiss idiom): session id · endpoint · path · state (`live` / `dead` /
  `unreachable`).
- Plain `list` never prompts: it silently GCs registry-local *dead* entries
  (ssh reachable, no server - harmless to drop) and reports *unreachable*
  ones without touching them. `:Outpost! list` is the only spelling that
  purges the flagged unreachable entries - typing the bang is itself the
  confirmation. GC/purge never touch anything on the remote.

### `:Outpost stop [target]`

- Bare `stop` opens a picker over registry entries in the *live*
  and *dead* states only - *unreachable* entries are excluded (nothing
  remote could be touched, so offering one would guarantee an error).
- A typed **long-form** target (`user@host:path`) re-runs the full identity
  ladder to resolve the session, exactly like `up`. A typed **short-form**
  target (session id) resolves via a registry lookup only; a miss is a
  clear error pointing at `:Outpost list`, never a fallback scan.
- Against a *live* resolved session: confirm (`vim.ui.select` yes/no, unless
  banged), then kill the session server, remove its `run/<session-id>/` dir,
  drop the registry entry. Project files are never touched.
- Against a *dead* resolved session: nothing to kill: `stop` still confirms,
  removes the stale `run/<session-id>/` dir, and drops the registry entry
  (a manual, single-target GC).
- Against an *unreachable* resolved session: errors clearly ("can't reach
  `<endpoint>`, nothing stopped") and leaves the registry entry flagged,
  untouched - it stays visible to `list!`'s purge rather than disappearing
  through a side door.

### `:Outpost down [host]`

- Bare `down` opens a picker over hosts that have at least one
  registry entry on this base (cheap: no ssh round trips to build the menu -
  consistent with `up`'s bare picker, which doesn't probe ssh-config hosts
  either). An outpost this base has never registered against isn't offered
  here, but `:Outpost down <host>` (typed) still reaches it.
- Before confirming, list the host's `~/.cache/outpost/run/` to report a
  concrete session count: "Destroy the outpost at `<host>`? This removes
  **3 sessions** and cannot be undone." (reuses the same run/-enumeration
  primitive `list`'s remote scan needs - the two share a module). Confirm
  (`vim.ui.select` yes/no, unless banged).
- Tear down the entire outpost: all sessions + portable install + synced
  config - everything under `~/.cache/outpost/` on that host. (The `up`/
  `down` pair: bring up or reuse vs. remove deployment.)

### `:Outpost update <host>`

- Re-resolve the latest release from `outpost-builds`, install to the host.
  Running sessions keep their loaded binary and pick the new one up on next
  `up`.

### `:Outpost sync [host]`

Sync is outpost-scoped and one-way: base → outpost, local is truth
(rule 2). Bare `sync` opens a picker over hosts with at least one
registry entry (cheap, no ssh round trips to build the menu - the same
policy as `down`'s picker); a typed `<host>` works for any ssh-config
host, erroring clearly if no outpost is there. No confirmation ever and
the bang is unused: sync only touches reproducible material - an outpost
rebuilt from (upstream release + base sync) loses nothing sync deleted.
The registry is untouched by sync, and the local registry
directory is itself part of the mandatory exclusion floor - it never
leaves the base.

**What syncs:** `stdpath("config")` and `stdpath("data")` wholesale,
into the outpost's XDG home (`config/nvim`, `data/nvim`).
`stdpath("state")` is never synced: undo/shada are per-machine, and
session state is lossy by policy. Config is verbatim, plugin
`.git` dirs included (lazy stays lockfile-happy). The resulting
invariant: an outpost's `config/` and `data/` are *exactly* the base's,
modulo exclusions - nothing remote-owned survives a sync.

**Exclusions - all hide-only** (excluded from transfer, deletable
remotely: rsync filter-rule flavor `hide`, not `protect`; plain
`--delete` is used and nothing is shielded from it):
- Mandatory floor, not removable via `setup`: `data/outpost/` (the
  local registry never leaves the base), `data/nvim/mason/` (LSP story
  deferred), `*.so` (see below).
- User excludes append to the floor: `setup({ sync = { exclude = ... }
  })` - rsync filter patterns, relative to the root being synced.

**Native artifacts never sync in v1 - unconditionally, not
arch-conditionally.** The outpost nvim is musl; parsers compiled on a
glibc base cannot be `dlopen`ed by it even on a perfect arch match, so
the earlier "match: sync `parser/*.so` as-is - they just work" semantics
were dead code in the common case. All `*.so` under the data root are
excluded; treesitter degrades cleanly on every outpost (no highlight,
everything else works) until v2's parser rebuild; the sync notification
says so. Sync therefore needs no architecture knowledge at all - arch
resolution stays where it belongs, in the install ladder.

**Remote-side parser builds (v1.5):** an outpost with the build toolchain
(`tree-sitter` CLI, a C compiler, `curl`, `tar`) can build parsers
on-session instead of degrading. Two rules make this safe:

1. **Never build under the synced trees.** The build output must live
   outside `config/` and `data/` (one-way `--delete` wipes anything
   remote-owned); the recommended `install_dir` for a session is
   `~/.cache/outpost/treesitter` - outpost-owned, never synced, wiped by
   `down`. `install_dir` is prepended to runtimepath by nvim-treesitter,
   so the session finds the parsers and queries.
2. **The toolchain must be on the session's PATH.** A session inherits
   sshd's non-interactive environment, not the login shell's: a CLI
   reachable in an interactive ssh shell may still be invisible to the
   session (typically missing `~/.cargo/bin`, `~/.local/bin`, profile
   shims). Config should probe (`executable()`) before calling
   `install()` so a toolchain-less outpost boots into the degraded mode
   instead of erroring.

A protect-rule flavor for the parser path remains the fallback if a
future story ever needs the builds under the data root (open question 2).
Empirically, `-f "P nvim/site/parser/**"` ordered before `H *.so` shields
remote-built parsers from `--delete` while base `*.so` still never
transfers.

**Prerequisite gates (one ssh round trip):** check the base's own
`rsync` first (clear error if missing); probe the *bundled* remote rsync
at `~/.cache/outpost/install/current/bin/rsync` - a missing binary or
outpost errors with "run `:Outpost up <host>` / `:Outpost update <host>`
first". The gate is the fallback; no tar-stream alternative and no
version→feature mapping tables. The same probe captures the absolute
`$HOME` (used verbatim in `--rsync-path`, no tilde expansion) and
pre-creates `~/.cache/outpost/{config,data}` with mode `0700`, so
synced content sits behind private ancestors regardless of file modes
(rule 7 pressure: config can contain tokens).

**Mechanics:** two sequential rsync invocations (config, then data);
success means both exited 0, and the sync marker is written only after
both. Flags: `-a --no-owner --no-group` (modes/times/symlinks
preserved, uid/gid never); symlinks are preserved as links and **never
followed** (`-L` forbidden - following could copy secrets or unbounded
trees; absolute out-of-root links simply dangle remotely, documented);
special files are skipped. `rsync -e` reuses the exact per-host
transport options (including mux `ControlPath` when configured).
Concurrent syncs from two bases onto one outpost are undefined - don't.

**Live sessions:** allowed, no restart (a restart would spend session
state nobody authorized spending), with an honest notification: "N live
session(s) are running from files sync just changed; they may misbehave
until restarted (`stop` + `up`)" - running servers lazily source runtime
files, so a mixed old/new tree is visible to them immediately.

**Runtime:** async job - "syncing `<host>`…" notification while running,
success notification with the two runs' aggregate stats, and the
`present.lua` float showing rsync output on failure.

**Known failure mode:** a stale outpost (config and
lazy dir out of sync) may see a plugin-manager bootstrap attempt
`git clone` through host git - which may fail (git is not bundled) or pull
from the internet. User-config territory; the fix is running `sync`, not
a guard.

**v2 (later):** download zig on **base** (self-contained static per-arch
binary from ziglang.org, matching the *remote* arch), scp it to the
outpost, and rebuild parsers there via `CC='zig cc'`. No compiler ships
in the bundle. Note the wipe interaction: v2's remote-rebuilt `*.so` are
remote-owned, and the hide-only exclusion deletes remote-owned material
on every sync - so v2 must either switch the parser path to a protected
exclusion flavor or re-trigger the rebuild on staleness (open question 2).

## Transport hardening

- **ControlMaster is opt-in per host** (shared/ephemeral hosts rot mux
  sockets): `setup({ hosts = { ["vps"] = { mux = true } } })`, default off.
  When on: `-o ControlMaster=auto -o ControlPath=<cache>/outpost/mux/%C
  -o ControlPersist=10m` on every plugin ssh/scp invocation.
- Remote `run/` tree is private (`umask 077`); sockets are 0600.
- rsync rides the same per-host options via `-e` (mux `ControlPath`
  included when configured); its `--rsync-path` uses the absolute
  `$HOME` captured by the sync gate probe, never tilde expansion.

## Completion

- `:Outpost <Tab>` → subcommands
- `:Outpost up <Tab>` → ssh-config hosts, then `host:path` combos from the
  registry
- `:Outpost stop <Tab>` → session ids in the *live* or *dead* state only
  (matching bare `stop`'s picker - *unreachable* entries are never offered)
- `:Outpost list|down <Tab>` → known hosts (registry ∪ ssh config), scoping
  the bare command's all-hosts default to one
- `:Outpost sync|update <Tab>` → known hosts

## Distribution

- Portable Neovim builds: https://github.com/juniorsundar/outpost-builds
  (hourly cron mirrors upstream stable releases; assets
  `nvim-portable-linux-{x86_64,aarch64}.tar.gz`).
- **Bundle v2 contents:** nvim + `rsync` (Alpine/musl, musl-loader wrapper
  pattern, ~1 MB cost, validated locally end-to-end). rsync makes `sync`
  host-independent. **git is deliberately NOT bundled** (vscode-server
  precedent: interactive tooling is the host's business; base-as-truth sync
  means lazy.nvim must never *need* to update on the remote;
  push-from-remote would additionally need a host ssh client, so bundling
  git buys less than it costs). If remote-commit workflow hurts later, revisit as bundle v3 -
  ideally with a bundled openssh client to make it a complete story.
  A compiler never ships (zig transfers from base on demand); node/LSP
  servers deferred until an airgap-aware Mason story exists.
- Client resolves `releases/latest` dynamically; no pinned tags in the plugin.
- The attach client is also an outpost-builds binary (same tag as remote),
  cached locally. `OUTPOST_NVIM` overrides.

## Open questions

1. ~~API detail to verify while building `up`: correlating `nvim_list_uis()`
   with `nvim_list_chans()` to obtain the channel id `chanclose()` needs.~~
   Resolved building `up`: verified against the fixture.
2. v2 parser rebuild: trigger mechanism (`nvim --headless` Lua invocation of
   nvim-treesitter) and zig version pinning - plus the wipe interaction with
   hide-only `*.so` exclusions (remote-rebuilt parsers are deleted by every
   sync). Resolved in v1.5 for user-config builds: build outside the synced
   trees (`~/.cache/outpost/treesitter`) where sync cannot wipe them; the
   protect-rule fallback is documented above. Zig pinning stays open for a
   plugin-orchestrated rebuild (a system C compiler on the remote is the
   remaining hard requirement).
3. ~~Plugin-manager dir detection beyond lazy.nvim (config escape hatch
   shape).~~ Dissolved: `sync` copies `stdpath("data")` wholesale rather
   than detecting a plugin manager's directory specifically.
4. Stale local attach-socket sweep: `up` clears stale local sockets for the
   target session before handing out the command; mux sockets swept too.
5. ~~OSC52 clipboard: shipped as a default remote-branch config snippet, or
   documented recommendation only?~~ Resolved: shipped as the default
   session branch, opt-out via `setup`.
6. Airgap-aware Mason/LSP story (Node does not ship in the bundle):
   `mason/` is excluded from sync by default, and the remaining question is
   how LSP servers reach the outpost at all - syncing base-built servers is
   as dead as parser syncing (musl remote cannot run glibc-built binaries),
   so the story needs remote-side installs or base-transferred musl-built
   runtimes.
