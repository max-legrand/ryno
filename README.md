# ryno

Review structured agent edits **inside your editor before they are applied**, like avante's legacy
mode. For arbitrary shell writes, choose a policy: block them where possible, review them after the
command, or let them pass. Works with **pi** and **prime-agent** (the Rust build), from **neovim** and
**vis**.

```
 pi / prime-agent ──(tool call gate)──▶ ryno extension ──unix socket──▶ nvim / vis
        ▲                                                                  │
        └────────────── accept · reject · partial (per hunk) ◀─────────────┘
```

* For structured **edit/write** calls, the agent extension computes the proposed change and sends
  `{original, proposed}` to a connected editor. With an editor connected, nothing touches disk until
  you answer. Arbitrary shell writes use the separate policy described below.
* **nvim** shows a cursorable review buffer: proposed lines are real buffer lines, while removed
  lines are shown as virtual lines above them. Syntax colors are retained on both sides of the diff;
  matching LSP clients can attach to the read-only proposed buffer for diagnostics, hover, completion,
  and navigation. The buffer uses a temporary same-directory URI; no preview file is written to disk.
  You can read long proposed sections with normal cursor movement and accept/reject **per hunk**.
* **vis** (no virtual text) shows a unified diff in a split; accept/reject the whole change.
* The agent is told what happened (rejected, or *"accepted 1 of 2 hunks"* with the rejected hunks
  listed), so it doesn't blindly retry or assume its edit landed whole.

## Install

### 1. Agent side

**pi** — load the extension (symlink or copy):

```sh
ln -s "$PWD/extension/ryno.ts" ~/.pi/agent/extensions/ryno.ts     # then /reload, or restart
# one-off: pi -e ./extension/ryno.ts
```

**prime-agent (Rust build)** — native extension (needs `node` ≥ 23.6 or `bun`, and `python3`). Add the
manifest to the **global** `~/.prime/agent/settings.json`, then start a new session:

```json
{ "nativeExtensions": ["/abs/path/to/ryno/extension/prime/extension.json"] }
```

### 2. Editor side

**neovim** (lazy.nvim):

```lua
{ name = "ryno", dir = "~/ml/ryno", opts = {} }   -- or anything that adds this repo to 'runtimepath'
```

It polls for agents whose working directory is the same as (or a parent/child of) nvim's cwd (symlinks
resolved) and connects to **all** of them, so a pi and a prime-agent in the same repo both work;
start agents before or after nvim. With several nvim instances connected to one agent, each review goes
to a single one: the instance that has the file open, else the one whose cwd contains the file (deepest
cwd first), and among equals the one you used most recently (nvim reports
its open files and activity to the agent; editors that report nothing, e.g. vis, are asked together as
before). Manual: `:RynoConnect` (`!` to pick any agent, ignoring cwd).

**vis**:

```sh
ln -s "$PWD/vis/ryno" ~/.config/vis/plugins/ryno
```
```lua
-- visrc.lua
require("plugins/ryno")   -- or require("plugins/ryno").setup{ auto_connect = false, keys = { accept = "<M-y>", reject = "<M-n>" } }
```

## Using it (nvim)

When the agent wants to edit a file, nvim opens a review buffer with the proposed version and removed lines shown above it (the winbar lists the keys):

| key (buffer-local, only during a review) | action |
| --- | --- |
| `<leader>ia` / `<leader>ir` | accept / reject the hunk under the cursor (then jumps to the next) |
| `<leader>iA` / `<leader>iR` | accept / reject all remaining hunks |
| `<leader>iu` | undo the decision for the hunk under the cursor (returns it to pending) |
| `<leader>ic` | comment on and reject the hunk under the cursor (or edit a rejected hunk's comment); included in the agent's feedback |
| `]c` / `[c` | next / previous pending hunk (lands on its first removed line) |
| `j` / `k` (`<Down>` / `<Up>`) | move through the removed (virtual) lines too: a highlighted `▶` line is the cursor; accept/reject apply to its hunk |

When no hunks are pending the decision is sent. All accepted → the agent's edit runs untouched. All
rejected → blocked. Mixed → the accepted hunks are written by the extension and the agent's call is
blocked with an explanation. The review buffer is read-only and cursorable; the real file buffer (including any unsaved changes)
is left untouched. After the agent applies an accepted change, nvim opens/reloads the file.

**Linking.** To pin an nvim to a specific agent session regardless of cwd, run `:RynoLink` and pick the
session (or `:RynoLink <pid>`). That nvim then connects *only* to the linked session(s), and the session
sends its reviews to the linked nvim before any other. `:RynoUnlink` goes back to cwd-based auto-connect;
links are forgotten when the session exits. The statusline shows `ryno⚭` while linked.

Commands: `:RynoLink [pid]` `:RynoUnlink` `:RynoConnect[!]` `:RynoDisconnect` `:RynoStatus` `:RynoAuto` (toggle auto-accept)
`:RynoAccept` `:RynoReject` `:RynoAcceptAll` `:RynoRejectAll` `:RynoNext` `:RynoPrev`.
Statusline: `require("ryno").status()`. `/ryno-bash review|block|off` changes the bash policy for this pi session; it does not persist the setting. Your local install sets the review keys to `<leader>i…` because `<leader>a` is used by Harpoon.

`:RynoAuto` is **ryno's** auto-accept toggle: while on, nvim accepts every incoming file-change review without asking. It is independent of pi's “auto-confirm shell commands” setting. Auto-confirming bash/read/git commands does not turn on `:RynoAuto` or bypass ryno's `edit`/`write` reviews. In bash `block` mode, the shell write restrictions still apply. Leave `:RynoAuto` off if every file change must be reviewed.

`open` chooses where the review appears: `"current"` (default; reuses the current window), `"split"`, `"vsplit"`, or `"tab"`. A split/tab is opened from the window showing the file and closed when the review ends (focus returns to where you were). With `focus=false` the new window opens without taking focus.

Options (defaults): `auto_connect=true, poll_ms=3000, match_cwd=true, auto_accept=false, focus=true,
open="current", ask_reason=false, keys={accept="<leader>ia", reject="<leader>ir", accept_all="<leader>iA",
reject_all="<leader>iR", next="]c", prev="[c", undo="<leader>iu", comment="<leader>ic"}`.

**Throwaway editors.** An nvim started as `$EDITOR` for `jj desc`, `git commit`, a rebase todo etc. is not
auto-connected, so it can't grab a review. It's decided once at startup, from the files nvim was opened with:
`exclude_filetypes={"jjdescription","gitcommit","gitrebase"}`, `exclude_patterns` (Lua patterns on the path,
e.g. `"%.jjdescription$"`, `"COMMIT_EDITMSG$"`), or your own `exclude=function() return … end`. Set
`RYNO_DISABLE=1` to keep any one nvim out. `:RynoConnect` / `:RynoLink` still work there if you ask.

## Using it (vis)

`:ryno-accept` (`<M-y>`) · `:ryno-reject [reason]` (`<M-n>`) · `:ryno-connect` · `:ryno-status` · `:ryno-auto`.
Needs `vis:communicate` and `nc -U` (or `socat`). Auto-connects at startup and when a window opens
(vis has no timers), otherwise `:ryno-connect`.

## Behaviour & limits — read these

* **Other confirm extensions get in the way.** pi runs `tool_call` handlers one after another, so a
  TUI prompt from another extension (e.g. `pi-confirm-changes`) must be answered *before* ryno's review
  even starts. Set that extension's edit/write rules to `allow` (`~/.pi/agent/operations.json`:
  `{"edit":"allow","write":"allow"}`) and let ryno be the gate.
* **Session changes** (`/new`, `/resume`, `/reload`) restart the agent-side socket; nvim notices
  (within `poll_ms`, 3 s by default) and reconnects. An edit made in that gap is not reviewed.
* Debugging: `RYNO_DEBUG=1` on the agent logs every decision (and why an edit was skipped) to
  `/tmp/ryno-debug.log`.

* **No editor connected:** structured edits proceed by default (`RYNO_NO_EDITOR=block` refuses instead). In bash `review` mode, no post-command review is started; in bash `block` mode, macOS sandboxing still applies in a git repo, while fallback rollback requires the extension to receive the tool result. If the editor disconnects mid-review, pending structured edits are rejected; post-hoc reviews keep changes if no editor can answer. `:RynoAuto` also accepts changes without review, so keep it off when approvals are required.
* **Changes made by shell commands** (`python3 - <<EOF … open(p,'w')`, `sed -i`, `>`, formatters…) can't
  be reviewed *before* they happen: the diff only exists once the command has run. Pick a policy in
  `~/.config/ryno/settings.json` (`{"bash": "block"}`), `RYNO_BASH=…`, or per pi session `/ryno-bash …`:

  | mode | what happens |
  | --- | --- |
  | `block` (recommended) | On macOS, ryno wraps the command in `sandbox-exec`; non-ignored files listed by git are read-only while it runs. Writes to ignored paths (e.g. `.zig-cache/`, `target/`, `node_modules/`) remain possible. Afterwards, ryno removes newly created, git-visible files. Without the macOS sandbox (prime-agent, or `RYNO_SANDBOX=off`), it snapshots and reverts detected changes after the command. |
  | `review` (built-in default when no setting overrides it) | Apply, then review detected changes marked **already applied**; *keep*, *roll back*, or keep some hunks. The command has already run (tests may have seen the new code). |
  | `off` | ryno ignores bash. |

  `~/.config/ryno/settings.json` sets the default for new sessions, e.g. `{"bash":"block"}`. A valid
  `RYNO_BASH=review|block|off` environment variable overrides it; pi's `/ryno-bash …` overrides
  both for that session. The setting-file default is `review`; your local install has set it to
  `block`. In `block` mode, edits made with structured `edit`/`write` tools are still reviewed before
  applying **when an editor is connected**. The agent is told to use those tools instead of shell writes. But **block mode is best-effort, not
  an OS-wide filesystem lock**: it only covers git repositories. Without a repository/snapshot, shell
  writes are not blocked or reverted. Ignored files are intentionally writable; ignored new files are
  not found by the post-command snapshot. Snapshot discovery is capped at 2000 paths; larger repos
  can have unsnapshotted paths. On macOS the sandbox covers up to 4000 non-ignored paths; above that,
  it falls back to post-command rollback. Without the sandbox, an interrupted command may not reach
  the rollback step. In `review` mode, binary/oversize files (>1 MB) are skipped and at most 20
  changed files are reviewed per command. If the editor is unreachable, changes are kept, never
  rolled back.

  `block` caveats: `git checkout/stash/reset`, `zig fmt`/`cargo fmt`, codegen into non-ignored files,
  and lockfile updates fail (ask the agent to tell you the command, or `/ryno-bash off` for a moment).
  Setuid programs can't run sandboxed: `ps`/`top` are allowed outside the sandbox, `sudo` is not.
* **prime-agent** edits files from Python: `await edit(path=…, old_str=…, new_str=…)` inside an
  `ipython` cell, so the gate only sees source code. ryno parses it (Python `ast`) and reviews the
  net change per file *before* the cell runs when the calls are top-level with string arguments that
  resolve statically (literals, `name = '''…'''` variables, `+`, simple f-strings). If you decline any
  file the *whole cell* is blocked. Everything else in the cell (computed edits, `open().write`,
  shell) falls under the shell policy above. In `block` mode, cells whose `edit()` arguments are only
  known at runtime are refused up front. prime-agent has no blocking post-tool hook, so results are
  delivered on the agent's *next* tool call (held until you've decided), or as a follow-up message
  if the turn already ended.
* prime-agent cancels a gate after **60 s** (host maximum); ryno answers at 55 s with a rejection
  ("no answer from the editor"). Override with `RYNO_TIMEOUT_MS`.
* Parallel sibling edits to the *same file* in one assistant message are reviewed against the same
  on-disk text; that is a pi scheduling property, not something ryno can serialise.
* The socket lives in `/tmp/ryno-<uid>/` (mode 0700/0600). Any process of your user can talk to it —
  same trust level as the agent itself. `RYNO_DIR` relocates it.

## Protocol (NDJSON over a unix socket, v1)

Discovery: `/tmp/ryno-<uid>/<pid>.json` = `{pid, cwd, socket, agent, sessionId, startedAt}`. Reviews may also include `post:true` (change already on disk) and `deleted:true`; on a post-hoc review, `reject` rolls back the change.

```
agent → editor   {"type":"hello","protocol":1,"pid","cwd","agent","sessionId"}
                 {"type":"review","id","tool","path","relpath","isNew","original":str|null,"proposed":str}
                 {"type":"resolved","id"}                   // answered elsewhere / aborted / timed out
                 {"type":"applied","id","path","ok"}         // file changed on disk: reload it
editor → agent   {"type":"decision","id","action":"accept"|"reject"|"partial",
                  "content"?,"reason"?,"accepted"?,"total"?,"rejected"?:[{"line","old","new"}]}
```

`original`/`proposed` are LF-normalised; for `partial` send the full resulting `content` (CRLF/BOM are
restored from the file on disk). Several editors may connect; the first answer wins and the others get
`resolved`.

## Layout

```
extension/ryno.ts            core + pi extension (socket server, edit semantics incl. fuzzy match)
extension/prime/             prime-agent adapter (JSON-RPC v3 shim + ipython-cell analysis)
lua/ryno/ plugin/ryno.lua    neovim plugin (client, inline review UI, pure diff/hunk logic)
vis/ryno/                    vis plugin (+ tiny JSON codec)
test/                        `make test` — unit + integration tests (real nvim/vis and macOS sandbox; mocked agent hosts)
```
