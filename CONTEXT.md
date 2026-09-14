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
| **instance id** | The UUID minted into an outpost at install time (`~/.cache/outpost/instance-id`). Identity anchor for sessions (see ADR-0009). |

## Artifacts

| Term | Definition |
| --- | --- |
| **bundle** | The portable musl tarball from outpost-builds: nvim + (v2) rsync. What an outpost is installed *from*. |
| **attach script** | The generated `<cache>/outpost/attach/<session-id>.sh` that `up` prints: opens its own tunnel, execs the attach client with `--remote-ui`, tears down on exit. (Never "launcher".) |
| **attach client** | The pinned outpost-builds nvim binary the attach script execs - same release tag as the remote install. Overridable via `OUTPOST_NVIM`. |
| **registry** | Local cache of known outposts/sessions for completion and display. Never authoritative (ADR-0005). |
| **manifest** | Per-session metadata in `run/<session-id>/` (path, endpoint, created) - what makes remote-scan discovery meaningful. |
| **control plane** | The plugin running inside the local nvim: manages outposts, owns no tunnels. (Never call it "the client".) |

## Verbs (the operational ladder)

`up` **provisions**, which means the idempotent ladder: resolve target →
expand endpoint → canonicalize path → **install** (portable nvim onto the
outpost) if needed → **start** (a session server) if needed → register →
print the attach command. Then the user **attaches** in a separate terminal;
closing that terminal **detaches** (session survives). **stop** kills one
session. **down** destroys the whole outpost. **update** re-installs the
bundle. **sync** pushes config/plugins base → outpost.

## Session states

| State | Meaning |
| --- | --- |
| **live** | ssh succeeds and the session socket answers a probe |
| **dead** | ssh succeeds, no session server for that id (GC removes registry entry) |
| **unreachable** | ssh itself fails (kept and flagged; purged only with `:Outpost! list`) |

## Vocabulary rules

- Never say "outpost" when you mean "session" (and vice versa). `sync`,
  `update`, `down` address **outposts**; `up`, `stop` address **sessions**.
- "Client" is forbidden unqualified - say **control plane** or **attach client**.
- Identity nouns: a session belongs to an **outpost** (account) and a
  **project** (canonical path); the **endpoint** is only how you reach it.
- Session state is **lossy by policy** (ADR-0006): detach preserves it, stop
  or a remote reboot destroys it - by design, not a bug.
