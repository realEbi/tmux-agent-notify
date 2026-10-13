# tmux-agent-notify

macOS notifications for AI agent CLIs running in tmux. Get a ping when a turn finishes or when the agent is waiting for you, then click the notification to jump back to the right pane.

Supported: Cursor (`agent`), Claude Code (`claude`) and the OpenAI Codex CLI (`codex`).

![Cursor notifications from tmux-agent-notify](docs/notification-sample.png)

## What you get

| When | Cursor | Claude Code | Codex |
| --- | --- | --- | --- |
| The agent needs your approval | **Cursor needs approval** | **Claude is waiting for you** | **Codex needs approval** |
| The agent asks you a question | **Cursor has a question** | **Claude is waiting for you** | not covered |
| A turn completes | **Cursor finished** | **Claude finished** | **Codex finished** |
| A turn ends with an error | **Cursor hit an error** | **Claude hit an error** | not available |

- Nothing is sent while you are looking at the pane, when you interrupt a turn, or when the agent is not running in tmux.
- If a prompt appears while you are looking and you switch away without answering it, you are notified at that moment.
- Clicking a notification brings the terminal forward and selects the pane.

## Requirements

- macOS and tmux, with the agent started inside a tmux pane.
- `jq` (ships with macOS 15 and later, otherwise `brew install jq`).
- `brew install terminal-notifier`, for click-to-focus. Without it you still get notifications, but clicking one opens Script Editor instead of your pane.

## Install

```bash
bin/install                 # every agent whose config directory exists (~/.cursor, ~/.claude, ~/.codex)
bin/install claude          # one agent
bin/install cursor claude   # the named agents
```

The installer keeps your other hooks and settings, and is safe to run again. Run it again after pulling changes or moving the directory, then start a new agent session so the hooks load.

Then do these once:

1. **Allow notifications for terminal-notifier.** Open System Settings → Notifications → **terminal-notifier** and turn on **Allow notifications**. Choose **Persistent** if you want a notification to stay until you click it.

   ![Notification settings for terminal-notifier](docs/terminal-notifier.png)

2. **Allow automation.** If macOS asks whether your terminal may control System Events, allow it. That is how the hooks tell whether you are looking at the pane.

3. **Codex only: trust the hooks.** The next time you start `codex` it shows "Hooks need review"; choose **Trust all and continue**. You can also run `/hooks` inside Codex.

## Try it

1. In a tmux pane, start your agent and ask it to run a command that needs your approval.
2. While the prompt is up, switch to another app. You should get the "waiting" notification. Claude Code sends it about six seconds after the prompt appears.
3. Approve it and stay away until the turn ends. You should get the "finished" notification.

## Troubleshooting

- **No notification at all.** Check that the agent was started inside tmux, that terminal-notifier is allowed (step 1 above), and that Focus or Do Not Disturb is off. For Codex, check that you trusted the hooks.
- **Clicking opens Script Editor.** terminal-notifier is not allowed to post notifications; see step 1 above.
- **terminal-notifier is missing from the Notifications list.** Trigger one notification first so macOS registers it. If you denied it earlier, run `tccutil reset UserNotification fr.julienxx.oss.terminal-notifier` and trigger one again.

## Good to know

- Claude Code: a prompt you answer within about six seconds never notifies.
- Codex: there is no error notification, and two sessions started in the same folder can be mixed up.
- A locked screen counts as looking, so walking away without switching app does not notify.

The full list of limitations, the settings, and how it all works are in [docs/architecture.md](docs/architecture.md). That page also explains how to add another agent and how to run the tests.
