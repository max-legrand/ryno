# ryno

Review structured agent edits **inside your editor before they are applied**, like avante's legacy
mode. For arbitrary shell writes, choose a policy: block them where possible, review them after the
command, or let them pass. Works with **pi**, **prime-agent** (the Rust build), **Claude Code** and
**Codex**, from **neovim** and **vis**.

```
 pi / prime-agent ──(tool call gate)──▶ ryno extension ──unix socket──▶ nvim / vis
        ▲                                                                  │
        └────────────── accept · reject · partial (per hunk) ◀─────────────┘

 Claude Code / Codex ──(PreToolUse / PostToolUse hooks)──▶ ryno-hook ──▶ ryno daemon (one per agent) ──▶ nvim / vis
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

**Claude Code / Codex** — hooks (needs `node` ≥ 23.6 on the agent's `PATH`). Print the configuration
with absolute paths filled in and merge its `hooks` into the agent's settings:

```sh
node extension/hooks/ryno-hook.ts --config claude   # → ~/.claude/settings.json (or a project's .claude/settings.json)
node extension/hooks/ryno-hook.ts --config codex    # → ~/.codex/hooks.json
```

Codex asks you to review/trust new hooks before it runs them. Codex fires `SessionStart` only when
the first message is sent, so editors can't see a fresh session until then. To make the socket exist
as soon as codex opens, start codex through the wrapper:

```sh
alias codex="$HOME/ml/ryno/bin/ryno-codex"      # in your shell rc; RYNO_CODEX=/path/to/codex if it's not on PATH
```

The hooks start a small daemon per agent process (`extension/hooks/ryno-daemon.ts`) that holds the
editor socket and runs the same core as the pi extension; it exits with the agent. Without the
wrapper, Codex's first hook starts it. The hook processes are short-lived and talk to it over
`/tmp/ryno-<uid>/hook-<agent pid>.sock`.

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

## Research/review mode (you write the code)

In Pi, use `/ryno-mode review` before asking about a bug or feature. The agent uses `ryno_findings`
to show file-anchored, read-only comment blocks in Neovim for file-specific guidance, including ordinary
implementation questions and hints (no explicit "review" request needed): where to look, why the change is needed,
conceptual implementation steps, and tests/edge cases. Chat gets a short summary. These are virtual
lines, not file edits, replacement implementations, approval diffs, or Neovim diagnostics.
Diagnostic navigation (`gn` / `gN`) ignores reviews; use `]r` / `[r` for review navigation.

Review blocks use dedicated purple highlights, separate from diagnostic/info colors. In files with
review comments, these buffer-local keys are available:

| Key | Action | Command |
| --- | --- | --- |
| `]r` / `[r` | Next/previous comment, wrapping across files | `:RynoNextFinding` / `:RynoPrevFinding` |
| `<leader>if` | List comments | `:RynoFindings` |
| `<leader>ih` | Hide/show all comment blocks | `:RynoToggleFindings` |
| `<leader>iH` | Hide all comment blocks | `:RynoHideFindings` |
| (command only) | Show all, including dismissed comments | `:RynoShowFindings` |
| `<leader>id` | Dismiss the comment anchored at the cursor | `:RynoDismissFinding` |
| `<leader>iD` | Dismiss all comments | `:RynoClearFindings` |

Hidden or dismissed comments show a purple `◆` in the sign-column gutter at their source line.
The marker follows edits and disappears when the comment is shown again. Higher-priority diagnostic
signs can take precedence; the sign column must be enabled (`:set signcolumn=auto` or `yes`).

Hiding and dismissing retain comments and their list entries. `<leader>ih` restores dismissed
comments (including dismiss-all); jumping to a dismissed or hidden comment also reveals it.
A new published review replaces the previous batch. Navigation follows the anchors as
you edit. Each published batch replaces that session's previous comments; an empty batch clears them.
Comments are independent of auto-accept.

Customize `findings_keys` in `require("ryno").setup` (set an individual key to `false` to disable it).
Override `RynoFindingTitle`, `RynoFindingBody`, `RynoFindingBorder`, and `RynoFindingHidden` through `hl`; highlights are
reapplied when the colorscheme changes. For example:

```lua
require("ryno").setup({
  findings_keys = { next = "]r", prev = "[r", toggle = "<leader>ih" },
  hl = {
    RynoFindingBody = { fg = "#d8cfe8", bg = "#252132" },
  },
})
```

No editor connected means feedback falls back to chat. After upgrading, `/reload` Pi
and restart Neovim to load the new socket handler. Old chat responses are not retroactively annotated.

Ryno never produces a replacement implementation. Make the change yourself,
save it, then run `/ryno-review [files or focus]`. The agent re-reads the saved files and reviews your
work, explaining problems without fixing them. Repeat as needed. Unsaved buffers are not reviewed.
You can also just ask for hints or say that your changes are ready for review.

`/ryno-mode edit` restores the usual Neovim edit-approval workflow. `/ryno-mode` and `/ryno-bash`
save their selections in the current Pi session, not in global settings. They survive reload and
resume; forks inherit the settings at the fork point, and tree navigation restores the active
branch's settings. Changes are only allowed while idle. A failed session save leaves the mode
unchanged. `/ryno-mode` shows the current mode without writing anything. The footer shows `REVIEW ONLY`.

Set new-session defaults in `~/.pi/agent/settings.json`:

```json
{ "ryno": { "mode": "edit", "bash": "block" } }
```

`edit` sends proposed edits to the connected editor for approval; `review` is research-only and
shows comments in Neovim without modifying code. Existing sessions keep their own settings when defaults change. On a new
session, valid `RYNO_MODE` / `RYNO_BASH` values override Pi defaults, which override the legacy
Ryno settings file. Session selections take precedence on reload/resume.
The default remains `edit` until you save a selection. You can also set it manually:

```json
{ "mode": "review" }
```

in `~/.config/ryno/settings.json`, or launch with `RYNO_MODE=review` (a new-session default).
In Pi, prefer the `ryno` section in Pi settings; commands only change the current session. Environment
values do not replace a saved session selection on reload or resume.
The legacy settings file also works for prime-agent, Claude Code and Codex. Those hosts use ordinary chat to request a
review after saving; the slash commands are pi-only. **Hook users must regenerate/merge `--config`
to install the wildcard `PreToolUse` matcher**, including if they already have ryno installed.

This is enforced at the tool gate, not just a prompt: edits, writes, patches, Python execution,
delegation, and unknown/custom tools are refused even without an editor connected or with auto-accept
on. Read/search/list tools and Pi's read-only `ryno_findings` tool remain available. In pi on macOS, shell research runs under a stricter
`sandbox-exec` policy denying **all filesystem writes and network access**, including ignored paths
and files outside git. If that sandbox is unavailable (including `RYNO_SANDBOX=off`), shell calls are
refused rather than run and rolled back. Prime-agent and hooks cannot safely rewrite shell commands,
so shell calls there are always refused in this mode. Ask the user to run tests needing writable
outputs/caches and share their results. On pi, enable the built-in `grep`, `find`, and `ls` tools if
you need search/listing without shell support (e.g. `pi --tools read,grep,find,ls,bash`).

Review mode overrides `RYNO_BASH` and `/ryno-bash`; bash `review` is a different policy that allows
changes and asks whether to keep them. No snapshots or rollback are used for review-only commands,
so your own saves are never reverted. Like all ryno gates, it covers agent tool calls, not manual
user shell commands, already-running commands, other extensions, or agents outside this session.
Use trusted local read/search/list tools; overriding them with mutating implementations defeats
that assumption. This is a learning workflow, not an isolation boundary for hostile code.

## Using it (nvim)

When the agent wants to edit a file, nvim opens a review buffer with the proposed version and removed lines shown above it (the winbar lists the keys):

| key (buffer-local, only during a review) | action |
| --- | --- |
| `<leader>ia` / `<leader>ir` | accept / reject the hunk under the cursor (then jumps to the next) |
| `<leader>iA` / `<leader>iR` | accept / reject all remaining hunks |
| `<leader>iu` | undo the decision for the hunk under the cursor (returns it to pending) |
| `<leader>ic` | comment on and reject the hunk under the cursor (or edit a rejected hunk's comment); included in the agent's feedback |
| `]c` / `[c` | next / previous hunk, including accepted/rejected ones (lands on its first removed line; shows a decided hunk's state and comment) |
| `<leader>is` | send the decision once every hunk is decided (only needed with `confirm_send=true`) |
| `j` / `k` (`<Down>` / `<Up>`) | move through the removed (virtual) lines too: a highlighted `▶` line is the cursor; accept/reject apply to its hunk |

Decided hunks stay visible: accepted ones are tinted and marked `✓`; a rejected hunk keeps the original
lines (marked `✗`) with a `✗ rejected: <comment>` header and the rejected proposal struck through above them.

When no hunks are pending the decision is sent. With `confirm_send=true`, deciding the last hunk one at a
time instead leaves the review open (winbar: `ready to send`) so you can still revisit, undo or comment;
send with `<leader>is` / `:RynoSend`. Accept all / reject all always send immediately. All accepted → the agent's edit runs untouched. All
rejected → blocked. Mixed → the accepted hunks are written by the extension and the agent's call is
blocked with an explanation. The review buffer is read-only and cursorable; the real file buffer (including any unsaved changes)
is left untouched. After the agent applies an accepted change, nvim opens/reloads the file.

**Linking.** To pin an nvim to a specific agent session regardless of cwd, run `:RynoLink` and pick the
session (or `:RynoLink <pid>`). That nvim then connects *only* to the linked session(s), and the session
sends its reviews to the linked nvim before any other. `:RynoUnlink` goes back to cwd-based auto-connect;
links are forgotten when the session exits. The statusline shows `ryno⚭` while linked.

Commands: `:RynoLink [pid]` `:RynoUnlink` `:RynoConnect[!]` `:RynoDisconnect` `:RynoStatus` `:RynoAuto` (toggle auto-accept)
`:RynoAccept` `:RynoReject` `:RynoAcceptAll` `:RynoRejectAll` `:RynoNext` `:RynoPrev` `:RynoSend`.
Statusline: `require("ryno").status()`. `/ryno-bash review|block|off` changes and persists the bash policy for this Pi session only. Your local install sets the review keys to `<leader>i…` because `<leader>a` is used by Harpoon.

`:RynoAuto` is **ryno's** auto-accept toggle: while on, nvim accepts every incoming file-change review without asking. It is independent of pi's “auto-confirm shell commands” setting. Auto-confirming bash/read/git commands does not turn on `:RynoAuto` or bypass ryno's `edit`/`write` reviews. In bash `block` mode, the shell write restrictions still apply. Leave `:RynoAuto` off if every file change must be reviewed.

`open` chooses where the review appears: `"current"` (default; reuses the current window), `"split"`, `"vsplit"`, or `"tab"`. A split/tab is opened from the window showing the file and closed when the review ends (focus returns to where you were). With `focus=false` the new window opens without taking focus. Set `review_in_file=true` to preview in the actual file buffer instead of a `.ryno` preview buffer; if the file isn't already loaded, ryno loads it for review. The preview is read-only and restored before the decision is sent; unsaved buffers fall back to a separate preview.

In Rex, `focus_pane` also moves keyboard focus to nvim's pane when a review opens (e.g. from the pi pane
beside it), but only when nvim's pane is in its session's active tab; it never switches tabs. Keys you
were typing elsewhere then go to nvim, so set `focus_pane=false` if that gets in the way.

Options (defaults): `auto_connect=true, poll_ms=3000, match_cwd=true, auto_accept=false, focus=true, focus_pane=true,
open="current", ask_reason=false, confirm_send=false, keys={accept="<leader>ia", reject="<leader>ir", accept_all="<leader>iA",
reject_all="<leader>iR", next="]c", prev="[c", undo="<leader>iu", comment="<leader>ic", send="<leader>is"}`.

**Throwaway editors.** An nvim started as `$EDITOR` for `jj desc`, `git commit`, a rebase todo etc. is not
auto-connected, so it can't grab a review. It's decided once at startup, from the files nvim was opened with:
`exclude_filetypes={"jjdescription","gitcommit","gitrebase"}`, `exclude_patterns` (Lua patterns on the path,
e.g. `"%.jjdescription$"`, `"COMMIT_EDITMSG$"`; pi's `/tmp/pi-editor-*` and macOS `$TMPDIR/pi-editor-*` paths, `rex-scrollback.txt`, and fish's temporary `command-line.fish`, are excluded by default), or your own `exclude=function() return … end`. Set
`RYNO_DISABLE=1` to keep any one nvim out. `:RynoConnect` / `:RynoLink` still work there if you ask.

## Using it (vis)

`:ryno-accept` (`<M-y>`) · `:ryno-reject [reason]` (`<M-n>`) · `:ryno-connect` · `:ryno-status` · `:ryno-auto`.
Needs `vis:communicate` and `nc -U` (or `socat`). Auto-connects at startup and when a window opens
(vis has no timers), otherwise `:ryno-connect`.

## Rex sound when a review is waiting

Ryno reports each waiting review to Rex as a `blocked` program status, and Rex plays its attention
sound for it, but only for tabs you aren't looking at. So when the first editor review starts
waiting, Ryno plays a sound itself only while you're looking at its tab: the agent's pane or a
connected nvim's pane has focus. Focus comes from terminal focus reports (which pi and nvim turn on)
and from keyboard input to the agent's pane; with neither yet, Ryno falls back to checking that its
pane is in its Rex session's active tab.

Known gap: Rex doesn't tell panes when you switch to *another session* (it does for other tabs), so
from another session you can hear both Rex's sound and Ryno's.

The sound is Rex's own attention sound if you've recorded it. Rex synthesizes its sounds rather than
shipping files, so record them once, from a terminal inside Rex (not from an agent's sandbox):

```sh
sh rex/record-rex-sounds.sh   # writes ~/.config/ryno/sounds/{attention,success,error}.caf
```

It builds a small capture app from `rex/capture-sound.swift`; macOS asks once for the System Audio
Recording permission. Without a recording, Ryno plays the system alert sound. `RYNO_SOUND=/path/to/file`
plays another file, `RYNO_SOUND=off` turns it off. Outside macOS Ryno rings the terminal bell.

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

  In Pi, `"ryno": {"bash":"block"}` in Pi settings sets the new-session default.
  `~/.config/ryno/settings.json` (`{"bash":"block"}`) remains a fallback and the default for other hosts.
  A valid `RYNO_BASH=review|block|off` overrides defaults for new sessions; Pi's `/ryno-bash …` saves
  the policy in that session only. The setting-file default is `review`; your local install has set it to
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
* **Claude Code / Codex** (hooks):
  * What's reviewed: Claude's `Write`, `Edit`, `MultiEdit`; Codex's `apply_patch` (also when sent as
    `apply_patch <<'EOF'` through the shell). A patch touching several files is reviewed file by file;
    if you decline any, the whole call is blocked, the files you accepted are written by ryno, and the
    agent gets the per-file outcome (like prime-agent's ipython cells). `NotebookEdit` isn't reviewed.
  * Hooks that run past their `timeout` are killed, and Claude Code then **proceeds without them**,
    so ryno answers 10 s early with a rejection. `--config` uses 600 s; if you change it, set
    `RYNO_HOOK_TIMEOUT` (seconds) to match. Interrupting the agent withdraws the review from the editor.
  * Accepting in the editor does not skip the agent's own permission prompt, so use Claude's
    accept-edits mode or set `RYNO_ALLOW_ACCEPTED=1` (e.g. in the `env` of `~/.claude/settings.json`) to
    have ryno answer `allow` for changes you accepted (Claude only; Codex has no such answer).
  * Bash `block` mode can't use ryno's sandbox here (the hooks can't rewrite commands, and Codex already
    sandboxes them): changes are reverted after the command and the agent is told. In `block` mode the
    policy is added to the agent's context at session start. There's no `/ryno-bash`: use
    `settings.json` or `RYNO_BASH`. A command whose post-tool hook never fires is settled at `Stop`.
  * Editors match on the session's project dir (`CLAUDE_PROJECT_DIR` for Claude, not its shell's current
    `cd`). `RYNO_DISABLE=1` in the agent's environment turns the hooks (and the wrapper) off.
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
extension/hooks/             Claude Code / Codex: hook command, per-agent daemon, Edit/apply_patch semantics
bin/ryno-codex               codex wrapper: opens the review socket before the first message
lua/ryno/ plugin/ryno.lua    neovim plugin (client, inline review UI, pure diff/hunk logic)
vis/ryno/                    vis plugin (+ tiny JSON codec)
test/                        `make test` — unit + integration tests (real nvim/vis and macOS sandbox; mocked agent hosts)
```
