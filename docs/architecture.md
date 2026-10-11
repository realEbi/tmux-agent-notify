# How tmux-agent-notify works

This page explains the design, the settings, and every known limitation. For installing and using the tool, see the [readme](../readme.md).

## Overview

Every hook runs `bin/notify <agent> <event>`. A small adapter per agent, in `bin/agents/`, reads the hook's payload and says whether the turn finished, failed, or is waiting for you. The hook always answers `{}`, so it never allows or denies anything.

| | Cursor | Claude Code | Codex |
| --- | --- | --- | --- |
| Config file | `~/.cursor/hooks.json` | `~/.claude/settings.json` | `~/.codex/hooks.json` |
| Turn finished | `stop` | `Stop` | `Stop` |
| Turn failed | `stop` | `StopFailure` | none |
| Waiting for you | `beforeShellExecution`, `beforeMCPExecution` | `Notification`, matcher `permission_prompt` | `PermissionRequest` |

For a waiting prompt, the hook starts a background watcher and returns at once. The watcher reads the tmux pane, notifies when the prompt is on screen and you are not looking, and stops quietly when the prompt is gone for two checks in a row. It checks every half second for the first two minutes, then every two seconds, for up to an hour.

No agent has a hook that says a prompt was answered, which is why the watcher reads the pane.

- **Cursor** has no hook for "an approval card is on screen", so the proposal of a command is used as the trigger and the watcher first waits for the card to appear. Commands that run without asking never show a card, so they never notify.
- **Claude Code** fires its notification hook about six seconds after a prompt appears, and only if it is still unanswered. A prompt you answer sooner never notifies.
- **Codex** fires `PermissionRequest` just before it draws the approval screen, so the watcher first waits for the screen to appear, as for Cursor.

Codex also needs one extra step. By default it runs hooks inside a shared background process, not inside the session in your pane, so the hook's `TMUX_PANE` can name another pane or be missing. The Codex adapter therefore looks for the `codex` process whose working directory is the folder in the hook's payload, and uses that process's tmux pane and terminal app. With `codex --no-daemon` the hook runs inside the session and nothing has to be looked up.

The watcher is started with `perl`, which ships with macOS, and payloads are read with `jq`.

## Settings

Environment variables tune the watcher. The defaults suit normal use; the tests shorten them. A value that is not a number is ignored and the default is used.

| Variable | Default | Meaning |
| --- | --- | --- |
| `NOTIFY_APPROVAL_DELAY` | `0.4` | Seconds before the first check of the pane (Cursor and Codex) |
| `NOTIFY_APPROVAL_INTERVAL` | `0.5` | Seconds between checks in the fast phase |
| `NOTIFY_APPROVAL_APPEAR_POLLS` | `40` | Checks to wait for the prompt to appear, about 20 seconds (Cursor and Codex) |
| `NOTIFY_APPROVAL_POLLS` | `240` | Checks in the fast phase (about 2 minutes) |
| `NOTIFY_APPROVAL_SLOW_INTERVAL` | `2` | Seconds between checks after the fast phase |
| `NOTIFY_APPROVAL_MAX_SECONDS` | `3600` | Seconds after which the watcher gives up without notifying |

`NOTIFY_APPROVAL_POLLS` used to be the whole budget. It is now only the length of the fast phase.

## Limitations

- Prompts are recognized by words on screen: `Esc to cancel` in the last three lines for Claude Code, `enter to confirm or esc to cancel` in the last three lines for Codex, and the card titles `Run this command?`, `Run this command outside the sandbox?` and `Run this MCP tool?` for Cursor. A new version that changes those words stops waiting notifications for that agent until its adapter is updated.
- Claude Code: the waiting notification arrives about six seconds after the prompt, and a prompt answered sooner never notifies.
- Claude Code: approvals and questions cannot be told apart, so both get the title **Claude is waiting for you**.
- Claude Code: a turn that hands work to a background subagent or shell ends at once, so **Claude finished** can arrive while that work continues. A later prompt from it notifies as usual.
- Claude Code: only tool approvals and questions have been checked. Other prompts notify only if their last three lines also contain `Esc to cancel`.
- Codex: you must trust the hooks once in Codex before they run (see the readme).
- Codex: there is no notification when a turn ends in an error, because Codex has no hook for it.
- Codex: two sessions started in the same folder cannot be told apart while Codex runs hooks in its background process. A notification for one may point at the other's pane. `codex --no-daemon` does not have this problem.
- Codex: a session started with `-C <dir>`, or from a folder other than the one it works in, is found only with `codex --no-daemon`. Otherwise the hook's own environment is used, which may name the wrong pane or none.
- Codex: only the approval prompts for shell commands and file edits have been checked. Other prompts, such as questions and plan approval, were not measured; they notify only if Codex fires `PermissionRequest` for them and their last three lines contain the same words.
- Codex: measured on Codex CLI 0.162.1.
- A locked screen counts as looking. The terminal stays in front when the screen locks, so walking away without switching app does not notify.
- A tmux session attached in a background tab or window of your terminal counts as looking too, as long as the terminal is the app in front.
- A config file that is a symlink is replaced by a regular file. The file it pointed at is left as it was.
- Cursor: a checkout path containing spaces is not supported, because the hook command is written unquoted.
- Cursor: approval cards in the Cursor IDE are not covered, because they are not shown in a tmux pane.
- Cursor: if you launch the Cursor IDE from inside a tmux pane, it can inherit `TMUX_PANE`, and its turns can notify too.

## Adding another agent

An agent is one file in `bin/agents/`. It names the agent's hooks, reads their payloads, and recognizes the agent's prompt in the pane text. The contract is described under "Adapter contract" in [the design](superpowers/specs/2026-10-08-tmux-agent-notify-design.md), and `bin/agents/cursor.sh` is a working example. `bin/agents/codex.sh` shows the two optional parts: finding the pane when the hook does not run inside it, and a note for the installer to print.

## Tests

```bash
bash tests/run.sh
```

No real agent is started; the tests use fakes for `osascript`, `terminal-notifier`, `tmux`, `ps` and `lsof`.
