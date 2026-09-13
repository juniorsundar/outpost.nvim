# Outpost — Design

Outpost is a vscode-server-like remote development layer for Neovim:
provision a portable, musl-bundled Neovim on a remote host, run a persistent
headless project session there, and attach a local `--remote-ui` client to it
from a separate terminal.

## Terminology and authority model

Four named entities — this vocabulary is normative for all other docs:

| Entity | What it is | Lifetime | Scope of |
| --- | --- | --- | --- |
| **base** | The local machine: credentials, config/plugin source of truth, the plugin (control plane), attaching clients | as long as the user lives there | `sync`, `update` (issuing), all lifecycle commands |
| **outpost** | The installation on one remote host: portable nvim install, synced config/plugins, session sockets — everything under `~/.cache/outpost/` | until destroyed; disposable by design (cattle) | `update`, `sync` (receiving) |
| **session** | One headless nvim server inside an outpost, bound to a project directory; owns editing state (buffers, LSP, terminals) | until `stop` or host death — *state is declared lossy by policy* | `launch`, `stop`, `list` |
| **project** | A directory on the remote. Pre-existing user data, **never owned by outpost** | not ours | nothing — outpost points at it, `stop` never touches it |

Rules:

1. The base is the only authority. Outposts/sessions never act autonomously
   (no self-update, no remote cron, no systemd units).
2. Material flows one way: config/plugins sync base → outpost, never back.
3. Outposts are disposable — reproducible from (upstream release + base sync).
   Destroying one loses nothing but session state.
4. Session state is the only non-reproducible thing, and is *lossy by policy*:
   a remote reboot or `stop` kills it, and that is by design, not a bug.
5. Credentials are forwarded (ssh-agent), never stored on the outpost.
6. Discovery scans the remote (`run/` directory is ground truth for sessions);
   the local registry is a cache/enrichment layer, reconciled on every `list`
   by every base. No base trusts its own registry over the remote.

## Core model

- **Outpost is a control plane.** The plugin runs inside a *local* nvim and
  manages remote sessions. It does not own tunnels or attached clients.
- **Sessions are project-scoped**, identified by `(user@host, absolute path)`.
  Each session is one headless remote nvim server with the project directory
  as its cwd and its own socket: `~/.cache/outpost/run/<hash>/nvim.sock`.
- **Attach is external and self-contained.** The plugin hands the user a
  launcher script; the script owns its tunnel + attaching client lifecycle and
  works independently of the nvim that launched it.
- **Sessions persist across attaches.** Detaching (closing the attaching
  terminal) leaves the remote server running. Only `stop` (or the remote host
  dying) destroys session state.
- **One UI client per session.** `--remote-ui` allows a single attached UI;
  launch must refuse (with a clear warning) when `nvim_list_uis()` shows one
  already attached.

## Session identity

- `hash = sha256(user@host + ":" + abspath)[:6]` (6 hex chars).
- Local registry: `stdpath("data")/outpost/registry.json` —
  `{hash, user@host, path, created_at, last_used_at}`.
- Host-wide portable install (shared by all sessions on that host):
  `~/.cache/outpost/install/current`, version pinned in
  `~/.cache/outpost/install/version`.

## Command surface

Single command, subcommand dispatch: `:Outpost <subcommand> [args]`
(`:Outpost! <subcommand>` = no-confirmation variant where applicable).

Targets: any command taking a target accepts either form — `<hash>` (short,
from `list`) or `<user@host>:<path>` — with completion always showing both
(`ab12cd  devbox:~/code/neovim (live)`). Neither form is primary.

### `:Outpost launch user@host:/abs/path`

1. Resolve the session hash; check the registry.
2. If a healthy session already exists for it (socket probe via
   `--remote-expr`), skip to 5 — launch is idempotent.
3. Otherwise provision: ensure the portable install (download from
   `outpost-builds` latest release, checksum, scp, extract — current logic),
   then start a headless server with cwd = the project path.
4. Register the session in the local registry.
5. Print the attach command: a generated launcher at
   `<stdpath cache>/outpost/attach/<hash>.sh`, which opens its own `ssh -L`
   tunnel to the session socket, runs `nvim --server <local-sock> --remote-ui`
   in the foreground, and tears its tunnel down on exit.

Warn if another UI client is already attached to the session.

### `:Outpost list`

- Scan the remote: for each known host (registry + ssh config), list
  `~/.cache/outpost/run/` — the remote is ground truth for sessions.
  Probe each found session (parallel, timeout-bounded) for liveness.
- Adopt sessions unknown to the local registry (e.g. started from another base).
- Show: hash · host · path · state (`live` / `dead` / `unreachable`).
- Garbage collection: registry-local removal of *dead* entries (ssh
  reachable, but no server). Entries where ssh itself fails are
  `unreachable`: kept and flagged by default; purged with `:Outpost! list`.
  GC never touches anything on the remote.

### `:Outpost stop <hash>`

- Kill the remote session server, remove its `run/<hash>/` dir, drop the
  registry entry. Confirmation unless banged.
- Scope: kills one *session*. The host-wide portable install is untouched
  (see `update`).

### `:Outpost update user@host`

- Re-resolve the latest release from `outpost-builds`, install to the host.
  Running sessions keep their loaded binary and pick the new one up on next
  launch.

### `:Outpost sync user@host`

- rsync plugins + runtime files, local machine → remote (local is the source
  of truth; no git bootstrap on the remote).
- Scope/exclusions TBD (config dir, plugin dirs; exclude `.git`?, compiled
  artifacts?). Known constraint: treesitter parsers are arch-specific — must
  be excluded on arch mismatch and rebuilt (requires a compiler on the
  remote; open question whether outpost-builds bundles one).

## Completion

- `:Outpost <Tab>` → subcommands
- `:Outpost launch <Tab>` → hosts from `~/.ssh/config`, then `host:path`
  combos from the registry
- `:Outpost stop <Tab>` → live session hashes
- `:Outpost sync|update <Tab>` → registry + ssh-config hosts

## Distribution

- Portable Neovim builds: https://github.com/juniorsundar/outpost-builds
  (hourly cron mirrors upstream stable releases; assets
  `nvim-portable-linux-{x86_64,aarch64}.tar.gz`).
- Client resolves `releases/latest` dynamically; no pinned tags in the plugin.

## Open questions

1. Path canonicalization: resolve with `realpath` on the remote before
   hashing, so trailing slashes / relative paths / symlinks don't fork
   session identity?
2. Second-attacher semantics: refuse (current decision), or take over by
   detaching the stale UI (`nvim_ui_detach`) before handing out the attach
   command?
3. Which nvim execs the attach script (PATH vs pinned `outpost-builds`
   binary downloaded locally for exact client/server parity)?
4. ssh ControlMaster multiplexing for all plugin invocations (missing from
   doc; cold `launch` currently implies ~7 sequential auth round-trips).
5. Socket permissions on shared remote hosts (chmod 700 run dir + socket).
6. `sync` scope definition: which dirs, `.git` in plugin trees keep/strip,
   treesitter parser strategy (exclude+rebuild needs compiler — or
   outpost-builds ships prebuilt parsers per arch).
7. `launch` with no path: error (path required) vs default `~`.
8. Where the attach command is presented: `:messages` vs floating buffer
   with automatic `+` yank.
9. outpost-builds bundle v2 contents: git? compiler? node?
10. Command naming: is `launch` right for an idempotent open-or-reuse verb?
    End-state shell shim (`outpost-attach <target>` that self-provisions
    headlessly, no local nvim required)?