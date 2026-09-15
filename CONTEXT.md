# CONTEXT.md - Outpost domain model

The normative vocabulary for outpost.nvim. `docs/DESIGN.md` carries the full
spec; this file fixes the *words*. When writing code, tickets, ADRs, tests,
or commit messages: use these terms, don't invent synonyms.

## Entities

| Term | Definition |
| --- | --- |
| **base** | The local machine: where the user lives. Owns credentials, the config/plugin source of truth, the plugin itself, and attaching terminals. |
| **outpost** | The installation under **one remote account** (`~/.cache/outpost/`): portable nvim, synced config/plugins, session sockets. Per-account, *not* per-machine - two accounts on one box are two outposts. Disposable (cattle). |
| **session** | One headless nvim server inside an outpost, bound to one canonical project path. Owns editing state (buffers, LSP, terminals). |
| **project** | A directory on the remote. Pre-existing user data, never owned by outpost; `stop` never touches it. |

## Identity

| Term | Definition |
| --- | --- |
| **target** | What the user types: `user@host:path` (host may be an ssh-config alias). |
| **endpoint** | The target after local `ssh -G` expansion: resolved `user@hostname`. **Transport-only** - used to reach an outpost, never to name it. |
| **canonical path** | The project path after `realpath` **on the remote**. Trailing slashes, relative segments, and symlinks must not fork identity. |
| **session id** | The 6-hex-char identifier of a session. "Hash" is the computation, "session id" is the noun. |
| **instance id** | The UUID minted into an outpost at install time (`~/.cache/outpost/instance-id`). Identity anchor for sessions. |

## Artifacts

| Term | Definition |
| --- | --- |
| **bundle** | The portable musl tarball from outpost-builds: nvim + (v2) rsync. What an outpost is installed *from*. |
| **attach script** | The generated `<cache>/outpost/attach/<session-id>.sh` that `up` prints: opens its own tunnel, execs the attach client with `--remote-ui`, tears down on exit. (Never "launcher".) |
| **attach client** | The pinned outpost-builds nvim binary the attach script execs - same release tag as the remote install. Overridable via `OUTPOST_NVIM`. |
| **askpass bridge** | The generated `<cache>/outpost/askpass.sh` plus the pair of per-invocation FIFOs it talks over: how an `ssh` the control plane spawned asks the **base** for a credential. Carries one answer in one direction and can execute nothing. (Never "askpass server" - there is no RPC channel into the editor.) |
| **registry** | Local cache of known outposts/sessions for completion and display. Never authoritative. |
| **manifest** | Per-session metadata in `run/<session-id>/` (path, endpoint, created) - what makes remote-scan discovery meaningful. |
| **control plane** | The plugin running inside the local nvim: manages outposts, owns no tunnels. (Never call it "the client".) |
| **session branch** | The plugin-shipped config branch that activates inside a session (`OUTPOST_SESSION=1`): OSC52 clipboard only. Environment restoration for child processes is start-script mechanics, never part of the branch. Opt-out via `setup`. (Never "workaround" or "remote config" - the user's config is verbatim.) |
| **sync marker** | The outpost-owned record at `~/.cache/outpost/synced` that a base→outpost sync has succeeded. `up` requires it before starting any session; `sync` writes it on success, never on failure. |

## Verbs (the operational ladder)

`up` **provisions**, which means the idempotent ladder: resolve target →
expand endpoint → canonicalize path → **install** (portable nvim onto the
outpost) if needed → **sync** (when freshly installed or the sync marker is
missing) → **start** (a session server) if needed → register →
print the attach command. Then the user **attaches** in a separate terminal;
closing that terminal **detaches** (session survives). **stop** kills one
session (or, against a *dead* one, just tidies it up - see below). **down**
destroys the whole outpost. **update** re-installs the bundle. **sync**
pushes config/plugins base → outpost.

## Interaction shapes

| Term | Definition |
| --- | --- |
| **bare picker** | A subcommand invoked with no target opens a `vim.ui.select` over its own candidates and re-enters itself with the choice. `up`, `stop`, `down`, `sync`
each have one; they are independent, not one shared UI. |
| **report** | A read-only rendering with no picker and no action attached. `list` is the only report; it never mutates a session or outpost, only the registry-local GC/purge described below. |
| **credential prompt** | The blocking ask the **base** puts to the user when `ssh` needs a secret or a host-key confirmation: `inputsecret()` for a secret, `confirm()` for a fingerprint. Raised only through the **askpass bridge**, never cached, and cancelling one aborts the whole operation. |

## Session states

| State | Meaning |
| --- | --- |
| **live** | ssh succeeds and the session socket answers a probe. Offered by `stop`'s picker; `stop` confirms, then kills the server, removes `run/<session-id>/`, drops the registry entry. |
| **dead** | ssh succeeds, no session server for that id. `list` GCs the registry entry silently, no confirm. Also offered by `stop`'s picker: confirms, then removes the stale `run/<session-id>/` dir and registry entry as a manual, single-target GC (there is no server to kill). |
| **unreachable** | ssh itself fails. Kept and flagged, never offered by `stop`'s picker (nothing remote could be touched). Untouched by plain `list`; purged only by `:Outpost! list` or resolved directly by a typed long-form target, which errors instead of acting. |

## Vocabulary rules

- Never say "outpost" when you mean "session" (and vice versa). `sync`,
  `update`, `down` address **outposts**; `up`, `stop` address **sessions**.
- "Client" is forbidden unqualified - say **control plane** or **attach client**.
- Identity nouns: a session belongs to an **outpost** (account) and a
  **project** (canonical path); the **endpoint** is only how you reach it.
- Session state is **lossy by policy**: detach preserves it, stop
  or a remote reboot destroys it - by design, not a bug.
- A **bare picker** is never a management buffer: it offers candidates for
  one re-entry into its own command, nothing more. Only `list` is
  a **report**; don't call a picker a report or vice versa. A **credential
  prompt** is neither: it is raised by the transport, not by a subcommand.
- The **base** owns credentials, so it is the only thing that may ask for
  one. An **outpost** never sees a credential, and the plugin never stores
  one: a secret lives for the duration of one **credential prompt**.
