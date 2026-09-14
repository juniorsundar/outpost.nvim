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
   own tooling is never a dependency.

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
  only, never part of identity (ADR-0009).
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
- Remote servers are started with `OUTPOST_SESSION=1` in their environment -
  the config's remote-behavior branch keys on it.

## Command surface

Single command, subcommand dispatch: `:Outpost <subcommand> [args]`
(`:Outpost! <subcommand>` = no-confirmation variant where applicable).

Targets: any command taking a target accepts either form - `<session id>`
(short, from `list`) or `<user@host>:<path>` - with completion always showing both
(`ab12cd  devbox:~/code/neovim (live)`). Neither form is primary.

### `:Outpost up [target]`

Bare `up` opens a `vim.ui.select` picker over live sessions, registry
entries, and ssh-config hosts - no path required up front.

With a target:

1. Resolve the endpoint locally (`ssh -G`); over ssh, fetch/mint the outpost
   instance id and canonicalize the project path (`realpath`); compute the
   session id; check the registry.
2. Healthy session already exists → skip to 6 (idempotent).
3. Otherwise provision: ensure the portable install (resolve
   `outpost-builds` latest release, download, checksum, scp, extract), then
   start a headless server with cwd = canonical project path, `umask 077`,
   `OUTPOST_SESSION=1`.
4. Register the session in the local registry.
5. Take over: `chanclose()` every attached UI; notify "detached existing
   UI".
6. Present the attach command: a floating window with the generated attach
   script (`<stdpath cache>/outpost/attach/<session-id>.sh`), auto-yanked into the `"`
   and `+` registers; any key dismisses. The script opens its own `ssh -L`
   tunnel, execs the pinned local outpost-builds client with
   `--remote-ui`, and tears the tunnel down on exit (best-effort `trap`).

### `:Outpost list`

- Scan each known host (registry + ssh config): list `~/.cache/outpost/run/`
  - the remote is ground truth; adopt sessions unknown to the local
  registry. Probe each found session (parallel, timeout-bounded) for
  liveness.
- Show: session id · endpoint · path · state (`live` / `dead` /
  `unreachable`).
- GC: registry-local removal of *dead* entries (ssh reachable, no server).
  ssh-unreachable entries are kept and flagged; purged with `:Outpost! list`.
  GC never touches anything on the remote.

### `:Outpost stop <target>`

- Kill one session server, remove its `run/<session-id>/` dir, drop the registry
  entry. Confirm unless banged. Project files are never touched.

### `:Outpost down <host>`

- Tear down the entire outpost: all sessions + portable install + synced
  config - everything under `~/.cache/outpost/` on that host. Confirm unless
  banged. (The `up`/`down` pair: bring up or reuse vs. remove deployment.)

### `:Outpost update <host>`

- Re-resolve the latest release from `outpost-builds`, install to the host.
  Running sessions keep their loaded binary and pick the new one up on next
  `up`.

### `:Outpost sync <host>`

- Syncs via rsync, base → outpost: `stdpath("config")` and the
  plugin-manager dir (lazy.nvim default `stdpath("data")/lazy`,
  configurable). Plugin `.git` dirs are kept (lazy stays lockfile-happy).
  One-way; local is truth.
- **No host dependency on rsync:** sync invokes the *bundled* rsync on the
  remote via `--rsync-path="~/.cache/outpost/install/current/bin/rsync"`.
  `sync` is version-gated on the outpost's bundle carrying rsync; older
  outposts are told to run `:Outpost update <host>` first. No tar-stream
  fallback - the gate is the fallback.
- **v1 arch semantics:** local and remote arch are both already known.
  - Match: sync compiled `parser/*.so` as-is - they just work.
  - Mismatch: sync everything *except* compiled parsers + warn
    ("treesitter disabled - arch mismatch"); treesitter degrades cleanly
    (no highlight, everything else works). No refusal.
- Config divergence: config is synced **verbatim**; remote-only behavior
  (OSC52 clipboard, etc.) branches inside the user's config on
  `OUTPOST_SESSION=1`, same pattern as existing `vim.g.vscode` branches.
- **v2 (later):** on parser mismatch, download zig on **base** (self-
  contained static per-arch binary from ziglang.org, matching the
  *remote* arch), scp it to the outpost, and rebuild parsers via
  `CC='zig cc'`. No compiler ships in the bundle.

## Transport hardening

- **ControlMaster is opt-in per host** (shared/ephemeral hosts rot mux
  sockets): `setup({ hosts = { ["vps"] = { mux = true } } })`, default off.
  When on: `-o ControlMaster=auto -o ControlPath=<cache>/outpost/mux/%C
  -o ControlPersist=10m` on every plugin ssh/scp invocation.
- Remote `run/` tree is private (`umask 077`); sockets are 0600.

## Completion

- `:Outpost <Tab>` → subcommands
- `:Outpost up <Tab>` → ssh-config hosts, then `host:path` combos from the
  registry; `:Outpost stop <Tab>` → live session ids
- `:Outpost sync|update|down <Tab>` → known hosts

## Distribution

- Portable Neovim builds: https://github.com/juniorsundar/outpost-builds
  (hourly cron mirrors upstream stable releases; assets
  `nvim-portable-linux-{x86_64,aarch64}.tar.gz`).
- **Bundle v2 contents:** nvim + `rsync` (Alpine/musl, musl-loader wrapper
  pattern, ~1 MB cost, validated locally end-to-end). rsync makes `sync`
  host-independent. **git is deliberately NOT bundled** (vscode-server
  precedent: interactive tooling is the host's business; base-as-truth sync
  means lazy.nvim must never update on the remote anyway; push-from-remote
  would additionally need a host ssh client, so bundling git buys less than
  it costs). If remote-commit workflow hurts later, revisit as bundle v3 -
  ideally with a bundled openssh client to make it a complete story.
  A compiler never ships (zig transfers from base on demand); node/LSP
  servers deferred until an airgap-aware Mason story exists.
- Client resolves `releases/latest` dynamically; no pinned tags in the plugin.
- The attach client is also an outpost-builds binary (same tag as remote),
  cached locally. `OUTPOST_NVIM` overrides.

## Open questions

1. API detail to verify while building `up`: correlating `nvim_list_uis()`
   with `nvim_list_chans()` to obtain the channel id `chanclose()` needs.
2. v2 parser rebuild: trigger mechanism (`nvim --headless` Lua invocation of
   nvim-treesitter) and zig version pinning.
3. Plugin-manager dir detection beyond lazy.nvim (config escape hatch shape).
4. Stale local attach-socket sweep: `up` clears stale local sockets for the
   target session before handing out the command; mux sockets swept too.
5. OSC52 clipboard: shipped as a default remote-branch config snippet, or
   documented recommendation only?
6. Airgap-aware Mason/LSP story: sync base's Mason dir to remote, defer, or
   accept no-LSP out of the box? (Node does not ship in the bundle for now.)
