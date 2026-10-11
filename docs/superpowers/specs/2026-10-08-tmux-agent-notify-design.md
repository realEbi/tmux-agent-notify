# tmux-agent-notify design

Status: implemented. Revised after an independent review, a second round of measurements, and a review of the implementation. Codex was added on 2026-10-11, after measurements on Codex CLI 0.162.1.

Date: 2026-10-08

Builds on [tmux-cursor-notify design](2026-09-29-tmux-cursor-notify-design.md). The **Focus check**, **Click**, and notification-posting rules in that document still apply unchanged and are not repeated here. Where the two documents disagree, this one wins.

## Goal

Make the tool work for any agentic CLI running in a local tmux pane, not only Cursor. Keep Cursor working as it does today, add Claude Code, and shape the design so Codex can be added next without changing the core. Codex has since been added. It needed one small addition to the core, the optional locator described under **Adapter contract**.

The user-visible behavior is the same for every agent:

- Notify when a turn finishes, and when it fails if the agent reports failures.
- Notify when the agent is waiting on the user (an approval, or a question).
- Stay silent while the user is looking at the pane. **If the user is looking when the agent starts waiting and then looks away, notify at that moment.** This holds for every agent; it is a requirement, not a Cursor detail.
- Clicking the notification focuses the pane.

## Decisions

1. **Rename.** The project is `tmux-agent-notify`. Scripts and titles no longer assume Cursor.
2. **One entry point, one adapter per agent.** Every hook runs `bin/notify <agent> <hook-event>`. The agent is named on the command line because it cannot be told from the payload: Claude Code and Codex send the same field names and the same `hook_event_name` values.
3. **Three kinds of event.** Each adapter maps its hook events to one of `finished`, `failed`, or `attention`. `failed` is optional; an agent without a failure hook never produces it.
4. **Look-away watcher for every agent.** An `attention` event starts a background watcher. The watcher notifies when the user is not looking, and stops when the wait is over.
5. **The wait is over when the prompt leaves the pane.** The watcher reads the tmux pane and asks the adapter whether its prompt is still on screen. This is what the Cursor watcher already does; it becomes the one mechanism for every agent. Hooks and the transcript file were both measured as alternatives and rejected; see **Measurements**.
6. **Claude Code uses the generic `Notification` hook** for `attention`. It covers permission prompts and questions with one hook. The richer `PermissionRequest` hook is not used.
7. **No two-minute limit.** The watcher keeps going while the prompt is on screen, up to an hour.
8. **Installer.** `bin/install` with no arguments installs for every agent whose config directory exists. `bin/install <agent>...` installs for the named agents only.
9. **Reply contract.** Every hook prints `{}` and exits 0, for every agent and every outcome. All three agents accept that as "no opinion".

## Agents

| | Cursor | Claude Code | Codex |
| --- | --- | --- | --- |
| Config file | `~/.cursor/hooks.json` | `~/.claude/settings.json` | `~/.codex/hooks.json` |
| Entry shape | `{command}` | `{matcher?, hooks: [{type: "command", command}]}` | same as Claude Code |
| `finished` | `stop`, `status: completed` | `Stop` | `Stop` |
| `failed` | `stop`, `status: error` | `StopFailure` | none |
| `attention` | `beforeShellExecution`, `beforeMCPExecution` | `Notification`, matcher `permission_prompt` | `PermissionRequest` |
| Prompt is on screen when the hook runs | no, it appears just after | yes | no, it appears about 0.13 seconds after |
| Hook runs inside the agent's pane | yes | yes | not by default; see **Codex adapter** |
| Session id | `conversation_id` | `session_id` | `session_id` |
| Folder | `workspace_roots[0]` | `cwd` | `cwd` |
| Label in titles | `Cursor` | `Claude` | `Codex` |

Notes:

- Claude Code's `Stop` does not fire on a user interrupt, and Cursor's `aborted` status is ignored, so an interrupted turn is silent for both.
- Codex's `Stop` fires only when a turn completes. An interrupt, or a denial with Esc, runs `Interrupt` instead, which is not hooked, so those are silent. Codex has no failure hook: there is no `StopFailure` and no `Notification` event. The Codex column was measured on Codex CLI 0.162.1 with a logging hook.
- Codex's older `notify` setting is not used. It is a single slot and may already be taken.

## Measurements

Measured on Claude Code 2.1.294 in a tmux pane, in two rounds. A logging hook recorded every hook event, one sampler recorded each line appended to the transcript, and another recorded each change of the pane's text. Runs: approve, deny, Esc, a question, parallel tool calls, a quick answer, a long-running approved command, a background task finishing during a prompt, and a prompt raised by a subagent.

What Claude Code tells us about a prompt:

- **`Notification` fires 6.0 seconds after the prompt appears**, and only if the prompt is still unanswered. Answered at 2.6 seconds, it did not fire.
- **A question is a `permission_prompt` too.** `AskUserQuestion` produced the same `notification_type` and the same `message`, `Claude needs your permission`. Approvals and questions cannot be told apart from this hook.
- Hooks inherit `TMUX_PANE` from the pane Claude Code runs in.

Why later hooks cannot say the wait is over:

- **Deny and Esc fire no hook at all.** No `PostToolUse`, no `Stop`, no `PermissionDenied`.
- **Approving a long command fires nothing until the command ends.** `PostToolUse` came 25 seconds after the approval of a 25-second command.

Why the transcript cannot say it either:

- **A background task writes to it while a prompt waits.** A background shell that finished 20 seconds into a waiting prompt appended a `queue-operation` line at that moment. A size check would end the watch with the prompt still up.
- **Approving a long command writes nothing until the command ends.** The `tool_result` line arrived with `PostToolUse`, 25 seconds later.
- **A subagent's prompt never touches the main transcript.** Approving it wrote only to the subagent's own file. The main file did not change until the subagent finished, 22 seconds later.

What the pane shows:

- **The last line of the pane that is not blank contains `Esc to cancel` for as long as a prompt is up.** Seen for a Bash approval (`Esc to cancel · Tab to amend`), a subagent's approval (the same, with more text after it), and a question (`Enter to select · ↑/↓ to navigate · Esc to cancel`).
- **A narrow pane wraps that line.** At 60 columns the subagent footer, 78 characters long, takes two lines, and the last one is `background agents`.
- **That line is gone within 0.3 seconds of the answer** in every run: approve, deny, Esc, question answered, long command approved, subagent prompt approved.
- It stayed in place through a 40-second wait while a background task finished.
- The pane's text as a whole changes about twice a second while a prompt is up, so comparing whole-screen snapshots does not work.

Also seen: a turn that starts a background subagent fires `Stop` at once, and the subagent's prompt arrives after it.

### Codex

Measured on Codex CLI 0.162.1 in a tmux pane 110 columns wide, with a logging hook on every event and a sampler on the pane's text. Runs: a shell command approved, a file edit (`apply_patch`) approved, and prompts ended with Esc.

What Codex tells us:

- **Config.** `~/.codex/hooks.json` has the same nested shape as Claude Code's `hooks` key. The file holds only hooks, plus an optional top-level `description`.
- **Payload.** JSON on stdin with `session_id`, `cwd`, `hook_event_name` and `turn_id`. `PermissionRequest` adds `tool_name` (`Bash`, `apply_patch`, or the name of an MCP tool), `tool_input.command`, and sometimes `tool_input.description`. For `apply_patch` the command is the whole patch text, many lines long, starting with `*** Begin Patch`.
- **Reply.** `{}` on stdout leaves the approval with the user.
- **`PermissionRequest` fires about 0.13 seconds before the approval screen is drawn.**
- **New hooks are skipped until the user trusts them.** At its next start Codex shows "Hooks need review" with a "Trust all and continue" choice; `/hooks` inside Codex does the same.

What the pane shows:

- **The last line of the pane that is not blank is `Press enter to confirm or esc to cancel` for as long as an approval screen is up**, for shell commands and for file edits.
- The screen does not change while the prompt is up.
- That line is gone as soon as the prompt is answered.

Where the hook runs:

- **By default Codex runs hook commands inside a shared background daemon** (`codex app-server --listen unix://... --managed-daemon`), not inside the session's own process. The hook's parent process is the daemon, and its `TMUX`, `TMUX_PANE` and `__CFBundleIdentifier` are the daemon's: those of wherever the daemon was first started. They can name the wrong pane, another tmux server or another terminal app, or be missing.
- With `codex --no-daemon` the hook's parent is the session's own `codex` process and the environment is right.
- The session's own process, the `codex` program running in the pane with a terminal attached, has the right three values in its environment. On macOS the same user can read them with `ps eww -o command= -p <pid>`.
- Its working directory, read with `lsof -a -d cwd -p <pid> -Fn`, equals the payload's `cwd` when Codex was started in that folder.
- **Nothing links a session id to a process.** The folder is the only key.

## Architecture

```
bin/notify              entry point for every hook
bin/agents/cursor.sh    Cursor adapter
bin/agents/claude.sh    Claude Code adapter
bin/agents/codex.sh     Codex adapter
bin/lib.sh              tmux, focus check, notification, watcher helpers
bin/focus-pane          notification click action (unchanged)
bin/install             installer
```

`bin/notify-on-stop` and `bin/notify-on-approval` are removed. Their logic moves into `bin/notify`, `bin/lib.sh`, and the Cursor adapter.

### Entry point

`bin/notify <agent> <hook-event>` reads the hook payload on stdin.

1. Source `bin/agents/<agent>.sh`. If the agent has no adapter, print `{}` and exit.
2. If `TMUX_PANE` is unset or empty and the adapter has no locator, print `{}` and exit. Cursor and Claude Code have none, so for them this is the old rule.
3. Ask the adapter to read the payload. An adapter that returns no kind means "ignore".
4. If there is a kind and the adapter has a locator, call it. It may replace `TMUX`, `TMUX_PANE` and `__CFBundleIdentifier`. If `TMUX_PANE` is still unset or empty afterwards, ignore the event.
5. Act on the kind (see **Event handling**).
6. Print `{}` and exit 0, whatever happened.

### Adapter contract

An adapter is a sourced bash file. It provides:

- A label for titles (`Cursor`, `Claude`).
- A parse step that takes the hook event name and the payload and sets: `kind` (one of the three, or empty), `session` (may be empty), `folder` (may be empty), `detail` (may be empty), and `title`.
- A prompt check: given the text of the pane and `detail`, say whether this agent's prompt is on screen.
- Whether the prompt is already on screen when the `attention` hook runs. Claude Code: yes. Cursor: no, the watcher must first wait for it to appear.
- Its hook list for the installer: for each hook, the event name and an optional matcher.

Two parts are optional:

- **A locator**, the function `agent_locate`, for an agent whose hooks may run outside its pane. The core calls it with no arguments, in the same shell, after the parse step and only when the kind is not empty. It can read what the parse step set; `folder` is still the whole path at that point. It may set and export `TMUX`, `TMUX_PANE` and `__CFBundleIdentifier`, or unset them. The rest of the hook run uses those values: the focus check, the pane check, the watcher (which inherits them) and the click command. Leaving `TMUX_PANE` empty means no notification. It must not block: a few quick commands at most. An adapter without the function is never asked, and for it nothing changes.
- **An install note**, the variable `AGENT_INSTALL_NOTE`: one line the installer prints, indented by two spaces, after the agent's `<agent>: <file>` line.

The parse step must treat the payload as data. Values are read with `jq` and never executed. Unreadable JSON, a non-object value, or missing fields give an empty kind.

How the contract is expressed in bash (functions, variables, naming) is the implementer's choice.

### Derived values

- **Group id:** `<agent>-<session>`, or `<agent>-unknown` when the session is empty. `finished`, `failed`, and `attention` for one session share a group, so a later notification replaces an earlier one.
- **Folder:** the last path component after stripping trailing slashes, as in the earlier spec. Empty falls back to `agent`.
- **Body length:** `detail` is cut to 80 characters, 79 plus `…`, when used as a body.

## Event handling

### finished and failed

1. If the terminal is frontmost and the pane is visible, stop.
2. Otherwise notify. Body is the folder.

Titles: `<Label> finished` and `<Label> hit an error`.

### attention

Start the watcher in the background with the agent name, pane, title, body, group, and `detail`, then return at once. The hook itself never notifies; the watcher's first poll does that when the user is already away.

Body is `detail` when present, otherwise the folder.

## Watcher

The watcher is the same script run again in its own session (`perl` fork plus `setsid`, output to `/dev/null`), as today, so it outlives the hook and the agent does not wait for it.

It reads the pane with `tmux capture-pane -p` and passes the text to the adapter's prompt check. On each poll:

1. If another watcher has taken over this pane, exit (see **One watcher per pane**).
2. Read the pane. If that fails, the pane or the tmux server is gone: exit without notifying.
3. If the prompt is not on screen:
   - when it has been seen before, or the adapter says it is on screen from the start: on the second poll in a row without it, the wait is over, so exit without notifying. One poll without it is not enough, because the pane may have been read in the middle of a redraw;
   - otherwise keep waiting for it to appear, and exit without notifying after `NOTIFY_APPROVAL_APPEAR_POLLS` polls (default 40).
4. If the prompt is on screen, take over the pane if this watcher has not done so yet (see **One watcher per pane**). Then, if the terminal is not frontmost or the pane is not visible, notify and exit.

Pacing: wait `NOTIFY_APPROVAL_DELAY` seconds (default 0.4) before the first poll when the adapter must wait for the prompt to appear, and not at all otherwise. Then poll every `NOTIFY_APPROVAL_INTERVAL` seconds (default 0.5) for the first `NOTIFY_APPROVAL_POLLS` polls (default 240), then every `NOTIFY_APPROVAL_SLOW_INTERVAL` seconds (default 2), until `NOTIFY_APPROVAL_MAX_SECONDS` (default 3600) have passed since the start. At that point exit without notifying.

This changes the meaning of `NOTIFY_APPROVAL_POLLS`: it was the whole budget and is now the length of the fast phase.

Each setting is checked once, when the watcher starts. The delay and the two intervals must be decimal numbers that are not negative; zero is allowed. The two poll counts and the maximum must be whole numbers above zero. Any other value is replaced by the default.

### One watcher per pane

A pane shows one prompt at a time, so one watcher per prompt is enough. Two can otherwise watch the same prompt, and both would notify: when the agent fires two hooks for it, or when a second prompt replaces the first faster than a poll can see the gap.

- The pane file is `${TMPDIR:-/tmp}/tmux-agent-notify/pane-<socket>-<pane id>`. The socket is the tmux socket path from `TMUX`, because every tmux server has a pane `%0`. In both parts, characters other than letters and digits are replaced (`%` is kept in the pane id), and both are cut to a fixed length, so the name stays short and inside the directory.
- A watcher takes over the pane on the first poll where it sees its own prompt, not at start. It writes its process id to the file, replacing what was there.
- Until then it holds no claim. It stops no other watcher, and no other watcher stops it. This matters for Cursor: a hook for command B can arrive while the card for command A is up. B's watcher never sees its own card, so A's watcher must be left alone.
- On each poll, a watcher that has taken over exits when the file holds another id. That other watcher has seen the same prompt and will notify for it.
- It removes the file when it exits, if the file still holds its id.
- If the file cannot be written or read, or is missing, the watcher carries on without it. A possible duplicate is better than no notification.

A watcher that holds no claim still ends in the usual ways: the appear polls run out, the prompt is gone for two polls, the pane cannot be read, or the time budget is reached. So none is left running.

Two watchers can still both notify when the second sees the prompt and notifies between two polls of the first, because it removes the file as it exits. That needs you to look away in that same moment, and the two notifications share a group.

## Claude Code adapter

| Hook | Matcher | Kind | Title |
| --- | --- | --- | --- |
| `Stop` | | `finished` | `Claude finished` |
| `StopFailure` | | `failed` | `Claude hit an error` |
| `Notification` | `permission_prompt` | `attention` | `Claude is waiting for you` |

Session is `session_id`. Folder comes from `cwd`.

`detail` is left empty for `attention`, so the body is the folder. The hook's `message` is the same for every prompt and says less than the folder does.

A `Notification` whose `notification_type` is not `permission_prompt` gives an empty kind, in case the matcher is edited by hand.

**Prompt check:** one of the last three lines of the pane that are not blank contains `Esc to cancel`. A line of only spaces or tabs is blank. Three lines are checked, not one, because a narrow pane wraps the footer. Lines further up are not checked, so the same words elsewhere in the conversation do not count. The prompt is on screen when the hook runs, because `Notification` arrives six seconds after it appears.

## Codex adapter

| Hook | Matcher | Kind | Title |
| --- | --- | --- | --- |
| `Stop` | | `finished` | `Codex finished` |
| `PermissionRequest` | | `attention` | `Codex needs approval` |

Session is `session_id`. Folder comes from `cwd`. `Interrupt` is not hooked. There is no `failed` kind.

`detail` for `PermissionRequest`:

- `apply_patch`: `Edit ` and the name of the first file in the patch, from its first `*** Add File:`, `*** Update File:` or `*** Delete File:` line. `Edit files` when there is none.
- any other tool: the first line of `tool_input.command`, or the tool's name when there is no command.

**Prompt check:** one of the last three lines of the pane that are not blank contains `enter to confirm or esc to cancel`. Blank lines and the reason for three lines are as for Claude Code. `detail` is not used. The prompt is not on screen when the hook runs, so the watcher waits for it to appear, as for Cursor.

**Locator.** `agent_locate` does this:

1. Read the command line of the hook's parent process (`ps -o command= -p $PPID`). If it is not a Codex `app-server`, stop: the hook runs inside the session and its environment is right.
2. If the payload has no `cwd`, stop.
3. List all processes (`ps -axo pid=,tty=,command=`) and keep the Codex sessions: a terminal is attached, the command line has a path ending in `codex`, and it has no `app-server` argument.
4. Read their working directories with one `lsof -a -d cwd -p <pids> -Fpn` call. Take the first one whose directory equals the payload's `cwd`. Both are resolved first, so `/tmp` equals `/private/tmp` and a trailing slash does not matter. A directory that no longer exists is compared as text.
5. If none matches, stop.
6. Read that process's environment (`ps eww -o command= -p <pid>`) as words separated by spaces, and take `TMUX`, `TMUX_PANE` and `__CFBundleIdentifier` from it. `TMUX_PANE` must look like `%12` and `TMUX` like `/path,1,0`. If either is missing or does not, both are unset, so a session that is not in tmux gets no notification. A missing `__CFBundleIdentifier` is unset too.

"Stop" in steps 1, 2 and 5, and any `ps` or `lsof` failure, keeps the hook's own environment. That is three `ps` calls and one `lsof` call at most.

**Install note:** tells the user to trust the new hooks at the next start of Codex, or with `/hooks`.

## Cursor adapter

Behavior is unchanged from the earlier spec, apart from the longer watcher budget. Only the wiring changes:

- `stop` maps `status: completed` to `finished` and `status: error` to `failed`; anything else is ignored.
- `beforeShellExecution` and `beforeMCPExecution` map to `attention`, with `detail` set to `command` or `tool_name`. Title `Cursor needs approval`.
- **Prompt check:** as today. One of the three card titles is in the last 15 lines of the pane, and when `detail` has 8 characters or more, its first 24 characters are there too. A card for a different command counts as not on screen.
- The prompt is not on screen when the hook runs.

## Installer

`bin/install [agent...]`

- No arguments: install for each known agent whose config directory exists (`~/.cursor`, `~/.claude`, `~/.codex`). If none exists, print an `install:` error and exit non-zero.
- With arguments: install for those agents, creating the config directory if needed. An unknown agent name is an error, and nothing is written for any agent.
- An agent named more than once is installed once, in the order first named.
- Print one line per agent installed: `<agent>: <file>`. When the adapter has an install note, print it on the next line, indented by two spaces.

Each agent's file is merged with `jq`, written to a temp file beside it, and moved into place, as today. The new file gets the permission bits of the file it replaces; a file that did not exist is created with mode 600, as `mktemp` makes it. A failure for one agent leaves that agent's file unchanged and makes the exit status non-zero; other agents are still attempted.

The hook command is `<bin>/notify <agent> <hook-event>`, where `<bin>` is the symlink-resolved directory of `bin/install`. Claude Code runs the command through a shell, so `<bin>/notify` is single-quoted in Claude Code's file. Codex's file is written the same way. Cursor's is written unquoted, as today.

**Removing our old entries.** Before adding, the installer removes entries left by an earlier install, for every event in the file, when the command (with any single quotes removed) is one of:

- `<bin>/notify-on-stop` or `<bin>/notify-on-approval`;
- any path ending in `/tmux-cursor-notify/bin/notify-on-stop` or `/tmux-cursor-notify/bin/notify-on-approval`;
- `<other>/bin/notify <agent> <event>` where `<other>` is not this checkout and its last component is `tmux-cursor-notify` or `tmux-agent-notify`.

A group left with no hooks is removed too. Entries that match none of these are never touched.

**Rename order.** Rename the directory first, then run `bin/install`. Until it is run, the hooks in `~/.cursor/hooks.json` point at the old path and do nothing.

**Cursor.** Same merge rules as the earlier spec, with the new commands. A missing or empty file, or one with only whitespace in it, is treated as `{}`.

**Claude Code.** In `~/.claude/settings.json`:

- A missing or empty file, or one with only whitespace in it, is treated as `{}`. All other keys are kept.
- For each hook, append `{"matcher": <matcher>, "hooks": [{"type": "command", "command": <command>}]}` to `hooks.<Event>`. Leave `matcher` out when the hook has none.
- Skip the append when any group under that event already contains a hook with the same `command`.
- Invalid JSON, a non-object root, a non-object `hooks`, or a non-array event leaves the file unchanged and reports an error.

**Codex.** In `~/.codex/hooks.json`, with the same rules as for Claude Code: a missing or empty file is treated as `{}`, `description` and other hooks are kept, a group is appended to `hooks.Stop` and to `hooks.PermissionRequest` without a matcher, and nothing is added twice. The installer cannot trust the hooks for the user, so it prints the adapter's install note.

Uninstall is out of scope.

## Error handling

Unchanged rules: the hook always prints `{}` and exits 0; a failed focus or pane-visibility check notifies; `terminal-notifier` failing falls back to `osascript`.

New:

- Unknown agent or unknown hook event: no notification.
- The watcher cannot read the pane: it exits without notifying. This replaces "a failed pane check notifies" inside the watcher only, so a killed pane does not produce a notification.

## Testing

Same approach: no real agent is started, and fakes for `osascript`, `terminal-notifier`, `tmux`, `mv`, `ps` and `lsof` sit first on `PATH`. The fake `ps` and `lsof` answer from files, one set per process id; the harness itself uses the real `ps` to find watchers.

Harness changes needed:

- The fake `tmux` and fake `osascript` must be able to read their answers from a file, so a test can change the pane text or the frontmost app while a watcher runs. Today they read fixed environment variables.
- Tests set `TMPDIR` to a temp directory. The watcher tests give the watcher a budget far longer than any test waits, so a watcher that exits did so for the reason under test. A test that fails stops the watchers it started.
- Existing installer tests that run with no arguments and expect `~/.cursor` to be created pass `cursor` instead.

Cases:

- **Core** (focus check, pane check, click command, fallback, `{}` on every path): the existing `notify-on-stop` cases, run through `bin/notify cursor stop`.
- **Cursor adapter:** the existing stop and approval cases under the new command names.
- **Claude Code adapter:** fixture payloads for each hook in the table. Titles, bodies, and groups; `Notification` with another type is silent; bad JSON is silent.
- **Codex adapter:** payloads and pane text as captured from Codex CLI 0.162.1. Titles, bodies, and groups; the detail for a shell command, a patch, and another tool; the prompt check on the captured screens; `Interrupt` and other events are silent; bad JSON is silent. Watcher: away, looking then away, answered then away, the prompt appears a few polls after the hook, and the prompt never appears.
- **Codex locator:** the hook's environment names pane A and the session for the payload's folder runs in pane B on another socket under another terminal app: every tmux call, the focus check, the pane file and the click command use B. No `TMUX_PANE` in the hook's environment still notifies. No session in the folder, a parent that is not the daemon, and a failing `ps` or `lsof` all keep the hook's environment. The daemon, processes without a terminal and other programs are not taken for sessions. `/tmp` against `/private/tmp`, and trailing slashes. A session outside tmux is silent. Text from `ps` and `lsof` is never executed. Cursor and Claude Code never call `ps` or `lsof`.
- **Watcher**, for the Cursor and Claude Code adapters unless noted:
  - Away when the prompt is up: notifies on the first poll.
  - Looking, then away with the prompt still up: notifies after the focus change.
  - Looking, then the prompt leaves the pane: exits without notifying, including when the user looks away afterwards.
  - One poll without the prompt, then the prompt again: keeps watching.
  - Claude Code: the prompt is not on screen at the first two polls: exits without notifying.
  - Claude Code: `Esc to cancel` four or more non-blank lines from the bottom does not count; a wrapped footer does.
  - Cursor: the prompt appears a few polls after the hook: notifies.
  - Cursor: the prompt never appears: exits after the appear polls.
  - Cursor: the card is on screen but above the last 15 lines: not a prompt.
  - The pane cannot be read: exits without notifying.
  - A second watcher that sees the same prompt makes the first exit, and one notification is posted.
  - Cursor: a second watcher for another command, whose card never shows, leaves the first running.
  - The same pane id on two tmux sockets: both watchers notify.
  - The fast phase uses the fast interval and the slow phase the slow one.
  - A setting that is not a number: the default is used.
  - Time budget reached while looking: no notification.
  - The hook returns before the watcher finishes.
- **Installer:** the existing Cursor cases; each removal rule, and an unrelated entry that survives; Claude Code create, merge, keep other keys and hooks, idempotent second run, matcher present only where specified, quoted path, invalid shapes left unchanged; Codex create, merge, idempotent second run, stale entries, invalid shapes, and the install note after its line only; no-argument agent detection; unknown agent name; a whitespace-only file; an agent named twice; permission bits kept.

Manual check for Claude Code, mirroring the Cursor one: trigger a permission prompt while away; trigger one while looking and then switch app; trigger one while looking, then approve, deny, and press Esc in turn, switching app after each and confirming silence; approve a long command and switch app while it runs, confirming silence; finish a turn while away.

## Readme

Rewrite for the new name, both agents, the `bin/install [agent...]` form, the rename order, and the settings table.

## Known limitations

- **Prompt text can change.** Every adapter recognizes its prompt by words on screen: `Esc to cancel` for Claude Code 2.1.294, `enter to confirm or esc to cancel` for Codex CLI 0.162.1, three card titles for Cursor. A new version that changes those words stops approval notifications for that agent until the adapter is updated.
- **Six-second delay (Claude Code).** An approval notification arrives six seconds after the prompt, because that is when Claude Code fires `Notification`. A prompt answered sooner never notifies.
- **Approval and question look the same (Claude Code).** Both get the title `Claude is waiting for you`.
- **"Finished" with background work still running (Claude Code).** A turn that hands work to a background subagent or shell ends at once, so `Claude finished` is posted while that work continues. A later prompt from it notifies as usual.
- **Hooks must be trusted (Codex).** Codex skips the hooks until the user has trusted them once, at start or with `/hooks`. The installer can only say so.
- **No error notification (Codex).** A turn that ends in an error runs no hook, so nothing is posted.
- **Two sessions in one folder (Codex).** While the daemon runs the hooks, the folder is the only link between a hook and its session. With two sessions started in the same folder, the first one found is used, so a notification may point at the other one's pane, and the focus check is about that pane too. `codex --no-daemon` avoids this.
- **A session whose folder differs from where it was started (Codex).** Started with `-C <dir>`, or from another folder than its working root, its process's working directory is not the payload's `cwd`, so the locator does not find it. The hook's own environment is then used. That is right with `codex --no-daemon`, and may be wrong or empty with the daemon.
- **Other Codex prompts were not measured.** Only the approval screens for shell commands and file edits were checked. Questions, plan approval and other prompts notify only if Codex fires `PermissionRequest` for them and one of their last three lines contains the same words.
- **The locator depends on what `ps` and `lsof` print on macOS** and on the daemon's command line holding `codex` and `app-server`. Environment values with spaces in them are not read correctly; a tmux socket path with a space makes the session count as outside tmux.
- **A locked screen counts as looking.** The terminal stays frontmost when the screen locks, so walking away without switching app does not notify.
- **A terminal in the background counts as looking.** The focus check asks which app is frontmost and whether the pane is the active one in an attached session. A session attached in a background tab or window of the frontmost terminal passes both.
- **A slow `osascript` delays everything behind it.** The focus check waits for `osascript`. If it hangs, for example on the first-run Automation dialog, the watcher's poll and the finished notification wait with it.
- **A config file that is a symlink is replaced by a regular file.** The installer moves a new file into place and does not follow the link. The file the link pointed at is left as it was.
- **Not measured:** prompts for a sandboxed command's network access, and Claude Code prompts other than tool approvals and questions. They notify only if one of their last three lines also contains `Esc to cancel`. A pane so narrow that the footer wraps inside those words, or onto more than three lines, is not recognized.
- **Cursor paths with spaces.** Cursor's command is written unquoted, so a checkout path containing spaces is not supported for Cursor.
- Cursor's limitations from the earlier spec still apply.

## Out of scope

- Trusting the Codex hooks for the user. That is a manual step in Codex.
- Uninstall.
- Per-agent settings for sound, titles, or which events notify.
- Everything listed as out of scope in the earlier spec.
