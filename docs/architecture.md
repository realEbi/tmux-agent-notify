# How tmux-agent-notify works

This page explains the design, the settings, and every known limitation. To install and use the tool, see the [readme](../readme.md).

## The short version

Each agent can run a command at certain moments, called hooks. The installer points those hooks at one script, `bin/notify`. Here is what happens when a hook fires:

1. The agent runs `bin/notify <agent> <event>` and passes details as JSON.
2. A small adapter for that agent reads the JSON and says what happened: the turn **finished**, it **failed**, or the agent is **waiting for you**.
3. For "finished" and "failed", a notification is sent, unless you are looking at the pane.
4. For "waiting for you", a background watcher starts. It notifies as soon as the prompt is on screen and you are not looking, and stops once you answer.
5. The hook always replies `{}` and returns at once. It never approves or denies anything.

**"Looking at the pane"** means two things are true: your terminal is the app in front, and the pane is the active pane of the active window in an attached tmux session.

**Clicking a notification** runs `bin/focus-pane`, which brings the terminal forward and selects the pane. Notifications from one session replace each other, so "finished" takes the place of an earlier "needs approval".

## The files

| File | What it does |
| --- | --- |
| `bin/notify` | The script every hook runs. It also contains the watchers. |
| `bin/agents/<agent>.sh` | One adapter per agent: its hooks, how to read their JSON, and how to recognize its prompt on screen. |
| `bin/lib.sh` | Shared helpers: sending a notification, checking whether you are looking, tmux calls. |
| `bin/focus-pane` | Runs when you click a notification. |
| `bin/install` | Writes the hooks into each agent's config file. |

## Which hooks are used

| | Cursor | Claude Code | Codex |
| --- | --- | --- | --- |
| Config file | `~/.cursor/hooks.json` | `~/.claude/settings.json` | `~/.codex/hooks.json` |
| Turn finished | `stop` | `Stop` | `Stop` |
| Turn failed | `stop` | `StopFailure` | none |
| Needs approval | `beforeShellExecution`, `beforeMCPExecution` | `Notification`, matcher `permission_prompt` | `PermissionRequest` |
| Asks a question | `beforeSubmitPrompt` until `stop` | `Notification`, matcher `permission_prompt` | not measured |

## The watcher

No agent has a hook that says "the prompt was answered". So the only way to know whether you still need to be told is to read the pane. That is the watcher's job.

- It reads the pane's text and looks for the words of the agent's prompt.
- If the prompt is on screen and you are not looking, it notifies and stops.
- If the prompt is gone for two checks in a row, you have answered, and it stops quietly.
- It checks every half second for the first two minutes, then every two seconds, for up to an hour.

This is what makes "look away later" work: if you are looking when the prompt appears and switch away without answering, the watcher is still running and notifies you then.

The watcher is started with `perl`, which ships with macOS, so that it keeps running after the hook has returned. Payloads are read with `jq`.

## Agent by agent

### Cursor

**Approvals.** Cursor has no hook for "an approval card is on screen". The hook fires when the agent proposes a command, so the watcher first waits for the card to appear. Commands that run without asking never show a card, so they never notify.

**Questions.** Cursor fires no hook at all for its question tool. Its docs say `preToolUse` fires for every tool, and Cursor has [confirmed the gap as a bug](https://forum.cursor.com/t/cursor-cli-askquestion-tool-skips-pretooluse-and-posttooluse-hooks/161836), with no fix so far. Until then, the whole turn is watched instead:

1. `beforeSubmitPrompt` fires when you send a prompt. It writes a token for this turn to a file for the pane, and starts a turn watcher.
2. The turn watcher notifies once for each question card that shows up while you are not looking.
3. `stop` fires when the turn ends, whatever its status, and deletes the file. The watcher runs only while the file holds its token, so it stops.

A few details follow from this:

- The hook writes the file before the watcher starts, so a turn that ends at once still stops it.
- A newer prompt writes a new token, which stops the older watcher.
- The turn watcher never takes over the pane, so approval watchers are left alone.

Once Cursor fixes the bug, a single `preToolUse` hook can replace the turn watcher.

### Claude Code

Claude Code fires its `Notification` hook about six seconds after a prompt appears, and only if the prompt is still unanswered. Approvals and questions both arrive this way. A prompt you answer sooner never notifies.

### Codex

**Approvals.** Codex fires `PermissionRequest` just before it draws the approval screen, so the watcher first waits for the screen to appear, as for Cursor.

**Finding the pane.** By default Codex runs hooks inside a shared background process, not inside the session in your pane. The hook's `TMUX_PANE` can therefore name another pane, or be missing. So the Codex adapter looks for the `codex` process whose working directory is the folder in the hook's payload, and uses that process's tmux pane and terminal app. With `codex --no-daemon` the hook runs inside the session and nothing has to be looked up.

## Settings

Environment variables tune the watcher. The defaults suit normal use; the tests shorten them. A value that is not a number is ignored and the default is used.

| Variable | Default | Meaning |
| --- | --- | --- |
| `NOTIFY_APPROVAL_DELAY` | `0.4` | Seconds before the first check of the pane (Cursor and Codex) |
| `NOTIFY_APPROVAL_INTERVAL` | `0.5` | Seconds between checks in the fast phase |
| `NOTIFY_APPROVAL_APPEAR_POLLS` | `40` | Checks to wait for the prompt to appear, about 20 seconds (Cursor and Codex) |
| `NOTIFY_APPROVAL_POLLS` | `240` | Checks in the fast phase, about 2 minutes |
| `NOTIFY_APPROVAL_SLOW_INTERVAL` | `2` | Seconds between checks after the fast phase |
| `NOTIFY_APPROVAL_MAX_SECONDS` | `3600` | Seconds after which the watcher gives up without notifying |
| `NOTIFY_TURN_MAX_SECONDS` | `86400` | Seconds after which a Cursor turn watcher gives up. Used only when the agent process was not found |

## Limitations

### All agents

- **Prompts are recognized by words on screen.** A new agent version that changes those words stops "waiting" notifications for that agent until its adapter is updated. The words are:

  | Agent | Words | Where |
  | --- | --- | --- |
  | Claude Code | `Esc to cancel` | Last three lines |
  | Codex | `enter to confirm or esc to cancel` | Last three lines |
  | Cursor, approvals | `Run this command?`, `Run this command outside the sandbox?`, `Run this MCP tool?` | Last 15 lines |
  | Cursor, questions | `Enter next/submit · Esc to skip`, or the placeholder of the input under the card | Last 15 lines |

- **A locked screen counts as looking.** The terminal stays in front when the screen locks, so walking away without switching app does not notify.
- **A background tab counts as looking.** A tmux session attached in a background tab or window of your terminal counts as looking, as long as the terminal is the app in front.
- **A symlinked config file is replaced by a regular file.** The file it pointed at is left as it was.

### Cursor

- **Spaces in the checkout path are not supported**, because the hook command is written unquoted.
- **The turn watcher has no time limit while the agent is alive.** The hook finds the agent process as its own ancestor whose parent is the pane's shell, and the watcher stops once that process is gone. The process is checked by id and start time, so a reused id does not count. After two minutes the watcher checks every two seconds.
- **When the agent process is not found**, for example when Cursor runs hooks in its background `worker-server`, the turn watcher stops after `NOTIFY_TURN_MAX_SECONDS` instead (a day by default).
- **Question notifications rely on `beforeSubmitPrompt` and `stop` firing in the interactive CLI.** Both were seen to fire on cursor-agent 2026.10.01, and answering `{}` to `beforeSubmitPrompt` did not hold the prompt back. Neither fires in print mode (`-p`), where questions are skipped anyway.
- **The Cursor IDE is not covered.** Its approval cards are not shown in a tmux pane.
- **An IDE launched from tmux can notify.** If you start the Cursor IDE from inside a tmux pane, it can inherit `TMUX_PANE`, and its turns can notify too.

### Claude Code

- **The waiting notification arrives about six seconds after the prompt.** A prompt answered sooner never notifies.
- **Approvals and questions cannot be told apart**, so both get the title **Claude is waiting for you**.
- **"Finished" can arrive while background work continues.** A turn that hands work to a background subagent or shell ends at once. A later prompt from that work notifies as usual.
- **Only tool approvals and questions have been checked.** Other prompts notify only if their last three lines also contain `Esc to cancel`.

### Codex

- **You must trust the hooks once** in Codex before they run (see the readme).
- **No error notification.** Codex has no hook for a turn that ends in an error.
- **Two sessions in the same folder cannot be told apart** while Codex runs hooks in its background process. A notification for one may point at the other's pane. `codex --no-daemon` does not have this problem.
- **A session started with `-C <dir>`**, or from a folder other than the one it works in, is found only with `codex --no-daemon`. Otherwise the hook's own environment is used, which may name the wrong pane or none.
- **Only approvals for shell commands and file edits have been checked.** Other prompts, such as questions and plan approval, were not measured. They notify only if Codex fires `PermissionRequest` for them and their last three lines contain the same words.
- **Measured on Codex CLI 0.162.1.**

## Adding another agent

An agent is one file in `bin/agents/`. It does three things:

1. Names the agent's hooks.
2. Reads their payloads.
3. Recognizes the agent's prompt in the pane text.

`bin/agents/cursor.sh` is a working example. `bin/agents/codex.sh` shows the two optional parts: finding the pane when the hook does not run inside it, and a note for the installer to print. The full contract is under "Adapter contract" in [the design](superpowers/specs/2026-10-08-tmux-agent-notify-design.md).

## Tests

```bash
bash tests/run.sh
```

No real agent is started. The tests use fakes for `osascript`, `terminal-notifier`, `tmux`, `ps` and `lsof`.
