#!/usr/bin/env bash
set -u
source "$(dirname "$0")/harness.sh"

run_hook() {
  local event=$1 json=$2
  export NOTIFY_APPROVAL_POLLS=1
  export NOTIFY_APPROVAL_INTERVAL=0
  export NOTIFY_APPROVAL_MAX_SECONDS=2
  if [ "${KEEP_PANE_UNSET-}" = 1 ]; then
    unset TMUX_PANE
  elif [ -z "${TMUX_PANE+x}" ]; then
    export TMUX_PANE=%12
  fi
  run_capture "$ROOT/bin/notify" cursor "$event" <<<"$json"
}

shell_json='{"command":"npm install deps","conversation_id":"c1","workspace_roots":["/tmp/app"]}'
mcp_json='{"tool_name":"search_docs","tool_input":"{\"query\":\"long enough\"}","conversation_id":"c1","workspace_roots":["/tmp/app"]}'

prompt_shell=$'line1\nRun this command?\nAllow once (y)\nnpm install deps'
prompt_mcp=$'Run this MCP tool?\nAllow once\nsearch_docs'

test_approval_no_pane() {
  harness_use_fakes
  KEEP_PANE_UNSET=1
  export NOTIFY_APPROVAL_DELAY=0
  run_hook beforeShellExecution "$shell_json"
  assert_exit 0
  assert_stdout_trimmed '{}'
  wait_quiet
  assert_not_called terminal-notifier
}

test_approval_no_prompt() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=0
  export FAKE_TMUX_CAPTURE=$'agent working\nno card here'
  run_hook beforeShellExecution "$shell_json"
  assert_exit 0
  assert_stdout_trimmed '{}'
  wait_quiet
  assert_not_called terminal-notifier
}

test_approval_shell_notifies() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=0
  export FAKE_OSA_NAME=Safari
  export FAKE_TMUX_CAPTURE="$prompt_shell"
  export TMUX=/tmp/sock,1,0
  export TMUX_PANE=%12
  export __CFBundleIdentifier=com.apple.Terminal
  run_hook beforeShellExecution "$shell_json"
  assert_exit 0
  assert_stdout_trimmed '{}'
  wait_for_notifier
  assert_notifier_arg -title 'Cursor needs approval'
  assert_notifier_arg -message 'npm install deps'
  assert_notifier_arg -group cursor-c1
  assert_notifier_arg -sound Glass
  local fp
  fp=$(cd "$ROOT/bin" && pwd -P)/focus-pane
  assert_log_contains terminal-notifier "'$fp'"
  assert_log_contains terminal-notifier "'%12'"
}

test_approval_mcp_notifies() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=0
  export FAKE_OSA_NAME=Safari
  export FAKE_TMUX_CAPTURE="$prompt_mcp"
  run_hook beforeMCPExecution "$mcp_json"
  wait_for_notifier
  assert_notifier_arg -title 'Cursor needs approval'
  assert_notifier_arg -message search_docs
  assert_notifier_arg -group cursor-c1
}

test_approval_stale_prompt_skipped() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=0
  export FAKE_OSA_NAME=Safari
  local pad i
  pad=$'Run this command?\nAllow once\nother-command-xyz'
  for i in $(seq 1 16); do
    pad=$pad$'\n'"pad-$i"
  done
  export FAKE_TMUX_CAPTURE="$pad"
  run_hook beforeShellExecution "$shell_json"
  wait_quiet
  assert_not_called terminal-notifier
}

test_approval_short_snippet_ok() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=0
  export FAKE_OSA_NAME=Safari
  export FAKE_TMUX_CAPTURE=$'Run this command?\nAllow once\nls'
  run_hook beforeShellExecution '{"command":"ls","conversation_id":"c1"}'
  wait_for_notifier
  assert_notifier_arg -title 'Cursor needs approval'
}

test_approval_visible_pane_silent() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=0
  export FAKE_OSA_NAME=Terminal
  export FAKE_TMUX_DISPLAY='1 1 1'
  export FAKE_TMUX_CAPTURE="$prompt_shell"
  run_hook beforeShellExecution "$shell_json"
  wait_quiet
  assert_not_called terminal-notifier
}

test_approval_returns_before_delay() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=5
  export FAKE_TMUX_CAPTURE="$prompt_shell"
  export TMUX_PANE=%w7
  harness_track_pane %w7
  # Avoid command substitution: bash waits for orphaned workers inside $().
  set +e
  "$ROOT/bin/notify" cursor beforeShellExecution <<<"$shell_json" >"$FAKE_LOG/hook.stdout"
  LAST_STATUS=$?
  set -e
  LAST_STDOUT=$(cat "$FAKE_LOG/hook.stdout")
  assert_exit 0
  assert_stdout_trimmed '{}'
  assert_not_called terminal-notifier
  # The watcher is still in its delay. Stop it so it does not outlive the test.
  wait_for_watchers %w7 1
  harness_kill_watchers %w7
  assert_no_watchers %w7
}

test_approval_other_command_silent() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=0
  export FAKE_OSA_NAME=Safari
  export FAKE_TMUX_CAPTURE=$'Run this command?\nAllow once\nother-command-xyz'
  run_hook beforeShellExecution "$shell_json"
  wait_quiet
  assert_not_called terminal-notifier
}

test_approval_body_is_folder_without_detail() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=0
  export FAKE_OSA_NAME=Safari
  export FAKE_TMUX_CAPTURE="$prompt_shell"
  run_hook beforeShellExecution '{"conversation_id":"c1","workspace_roots":["/tmp/app/"]}'
  wait_for_notifier
  assert_notifier_arg -title 'Cursor needs approval'
  assert_notifier_arg -message app
}

test_approval_long_body_cut() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=0
  export FAKE_OSA_NAME=Safari
  local cmd
  cmd=$(printf 'x%.0s' $(seq 1 100))
  export FAKE_TMUX_CAPTURE=$'Run this command?\n'"$cmd"
  run_hook beforeShellExecution "$(jq -nc --arg c "$cmd" '{command: $c, conversation_id: "c1"}')"
  wait_for_notifier
  assert_notifier_arg -message "${cmd:0:79}…"
}

test_approval_non_object_payload() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=0
  export FAKE_OSA_NAME=Safari
  export FAKE_TMUX_CAPTURE="$prompt_shell"
  run_hook beforeShellExecution '["npm install deps"]'
  assert_exit 0
  assert_stdout_trimmed '{}'
  wait_quiet 1
  assert_not_called terminal-notifier
  assert_not_called tmux
}

# The watcher tests below start with the card up and you looking at the pane.
# watch_setup PANE sets that scene; a test may change the scene or the pacing
# before watch_hook starts the watcher. The time budget is far longer than any
# test waits, so a watcher that exits did so for the reason under test.
watch_setup() {
  harness_use_fakes
  export TMUX_PANE=$1
  harness_track_pane "$1"
  export __CFBundleIdentifier=com.apple.Terminal
  fake_set osa-bundle com.apple.Terminal
  fake_set tmux-display '1 1 1'
  fake_set tmux-capture "$prompt_shell"
  export NOTIFY_APPROVAL_DELAY=0
  export NOTIFY_APPROVAL_INTERVAL=0.1
  export NOTIFY_APPROVAL_POLLS=1000
  export NOTIFY_APPROVAL_SLOW_INTERVAL=0.1
  export NOTIFY_APPROVAL_MAX_SECONDS=30
}

# watch_hook [JSON]
# Not through run_capture: bash waits for orphaned workers inside $().
watch_hook() {
  local status=0
  "$ROOT/bin/notify" cursor beforeShellExecution <<<"${1-$shell_json}" >"$FAKE_LOG/hook.stdout" || status=$?
  [ "$status" = 0 ] || { echo "hook exited with $status" >&2; exit 1; }
  [ "$(cat "$FAKE_LOG/hook.stdout")" = '{}' ] || { echo "hook did not print {}" >&2; exit 1; }
}

look_away() {
  fake_set osa-bundle com.example.Other
}

test_watch_look_then_away() {
  watch_setup %w1
  watch_hook
  wait_for_polls 2
  assert_not_called terminal-notifier
  look_away
  wait_for_notifier
  assert_notifier_arg -title 'Cursor needs approval'
  assert_notifier_arg -message 'npm install deps'
  assert_no_watchers %w1
  assert_notifier_calls 1
}

test_watch_answered_then_away() {
  watch_setup %w2
  watch_hook
  wait_for_polls 2
  fake_set tmux-capture 'agent working'
  # The watcher is gone before you look away, so nothing is left to notify.
  assert_no_watchers %w2
  look_away
  wait_quiet 0.5
  assert_not_called terminal-notifier
}

test_watch_pane_gone() {
  watch_setup %w3
  watch_hook
  wait_for_polls 2
  fake_set tmux-capture-exit 1
  assert_no_watchers %w3
  look_away
  wait_quiet 0.5
  assert_not_called terminal-notifier
}

# Two hooks for the same command: the first watcher stops while you are still
# looking, and the one that is left notifies once.
test_watch_second_replaces_first() {
  local polls
  watch_setup %w4
  watch_hook
  wait_for_polls 2
  wait_for_watchers %w4 1
  watch_hook
  wait_for_watchers %w4 1
  # The watcher that is left is still polling.
  polls=$(tmux_calls display-message)
  wait_for_polls $((polls + 2))
  assert_not_called terminal-notifier
  look_away
  wait_for_notifier
  wait_quiet 0.5
  assert_notifier_calls 1
  assert_no_watchers %w4
  # The last watcher cleans up the pane file.
  [ -z "$(ls -A "$TMPDIR/tmux-agent-notify")" ] ||
    { echo "pane file left behind: $(ls -A "$TMPDIR/tmux-agent-notify")" >&2; exit 1; }
}

# A hook for another command arrives while the card for the first is up. Its
# watcher never sees its own card, so it must not stop the first one.
test_watch_other_command_keeps_first() {
  watch_setup %w13
  export NOTIFY_APPROVAL_APPEAR_POLLS=3
  watch_hook
  wait_for_polls 2
  watch_hook '{"command":"cargo build --release","conversation_id":"c1","workspace_roots":["/tmp/app"]}'
  # The second watcher gives up after its appear polls; the first stays.
  wait_for_watchers %w13 1
  assert_not_called terminal-notifier
  look_away
  wait_for_notifier
  assert_notifier_arg -message 'npm install deps'
  assert_no_watchers %w13
  assert_notifier_calls 1
}

# Every tmux server has a pane %0. Watchers for the same pane id on two
# servers do not stop each other.
test_watch_same_pane_other_server() {
  local polls
  watch_setup %w14
  export TMUX=/tmp/sock-a,1,0
  watch_hook
  wait_for_polls 2
  export TMUX=/tmp/sock-b,1,0
  watch_hook
  polls=$(tmux_calls display-message)
  wait_for_polls $((polls + 6))
  wait_for_watchers %w14 2
  [ "$(ls -A "$TMPDIR/tmux-agent-notify" | sort | tr '\n' ' ')" = 'pane-_tmp_sock_a-%w14 pane-_tmp_sock_b-%w14 ' ] ||
    { echo "unexpected pane files: $(ls -A "$TMPDIR/tmux-agent-notify")" >&2; exit 1; }
  look_away
  wait_for_notifier_calls 2
  assert_log_contains terminal-notifier "'/tmp/sock-a' '%w14'"
  assert_log_contains terminal-notifier "'/tmp/sock-b' '%w14'"
  assert_no_watchers %w14
  assert_notifier_calls 2
  [ -z "$(ls -A "$TMPDIR/tmux-agent-notify")" ] ||
    { echo "pane file left behind: $(ls -A "$TMPDIR/tmux-agent-notify")" >&2; exit 1; }
}

# One capture without the card, as in the middle of a redraw, does not end the
# watch. Two in a row do; test_watch_answered_then_away covers that.
test_watch_one_miss_keeps_watching() {
  local polls
  watch_setup %w15
  watch_hook
  wait_for_polls 2
  fake_set tmux-capture-once 'agent working'
  wait_for_capture_once
  polls=$(tmux_calls display-message)
  wait_for_polls $((polls + 2))
  look_away
  wait_for_notifier
  assert_no_watchers %w15
  assert_notifier_calls 1
}

# An interval that is not a number falls back to the default of half a second,
# instead of polling without a pause.
test_watch_bad_interval() {
  watch_setup %w16
  export NOTIFY_APPROVAL_INTERVAL=abc
  export NOTIFY_APPROVAL_SLOW_INTERVAL=fast
  watch_hook
  wait_for_polls 1
  wait_quiet 1.5
  [ "$(tmux_calls display-message)" -le 6 ] ||
    { echo "polled $(tmux_calls display-message) times in 1.5 seconds" >&2; exit 1; }
  look_away
  wait_for_notifier
  assert_no_watchers %w16
  assert_notifier_calls 1
}

# A budget that is not a whole number above zero falls back to the default.
test_watch_bad_max_seconds() {
  local max
  for max in 1.5 abc 0; do
    watch_setup %w17
    export NOTIFY_APPROVAL_MAX_SECONDS=$max
    watch_hook
    wait_for_polls 2
    look_away
    wait_for_notifier
    assert_no_watchers %w17
    assert_notifier_calls 1
  done
}

test_watch_card_appears_later() {
  watch_setup %w9
  fake_set tmux-capture $'agent working\nno card yet'
  look_away
  watch_hook
  wait_for_captures 3
  assert_not_called terminal-notifier
  fake_set tmux-capture "$prompt_shell"
  wait_for_notifier
  assert_notifier_arg -title 'Cursor needs approval'
  assert_notifier_arg -message 'npm install deps'
  assert_no_watchers %w9
  assert_notifier_calls 1
}

# The card never shows up: the watcher stops after the appear polls, long
# before the time budget.
test_watch_card_never_appears() {
  watch_setup %w10
  export NOTIFY_APPROVAL_APPEAR_POLLS=5
  fake_set tmux-capture $'agent working\nno card here'
  look_away
  watch_hook
  assert_no_watchers %w10
  [ "$(tmux_calls capture-pane)" = 5 ] ||
    { echo "expected 5 capture-pane calls, saw $(tmux_calls capture-pane)" >&2; exit 1; }
  fake_set tmux-capture "$prompt_shell"
  wait_quiet 0.3
  assert_not_called terminal-notifier
}

# The card for this very command is on screen, but above the last 15 lines.
test_watch_card_above_window() {
  watch_setup %w11
  export NOTIFY_APPROVAL_APPEAR_POLLS=3
  local pad=$prompt_shell i
  for i in $(seq 1 16); do
    pad=$pad$'\n'"pad-$i"
  done
  fake_set tmux-capture "$pad"
  look_away
  watch_hook
  assert_no_watchers %w11
  assert_not_called terminal-notifier
  [ "$(tmux_calls capture-pane)" = 3 ] ||
    { echo "expected 3 capture-pane calls, saw $(tmux_calls capture-pane)" >&2; exit 1; }
}

# Five quick polls, then one every ten seconds.
test_watch_fast_then_slow() {
  watch_setup %w12
  export NOTIFY_APPROVAL_POLLS=5
  export NOTIFY_APPROVAL_INTERVAL=0.1
  export NOTIFY_APPROVAL_SLOW_INTERVAL=10
  watch_hook
  # Fast phase: with the slow interval, five polls would take 40 seconds.
  wait_for_polls 5
  # Slow phase: with the fast interval, 1.5 seconds would add several polls.
  wait_quiet 1.5
  [ "$(tmux_calls display-message)" -le 6 ] ||
    { echo "slow phase polled $(tmux_calls display-message) times" >&2; exit 1; }
  wait_for_watchers %w12 1
  # The watcher is in a ten-second sleep. Stop it rather than wait.
  harness_kill_watchers %w12
  assert_no_watchers %w12
  assert_not_called terminal-notifier
}

test_watch_budget_reached() {
  watch_setup %w5
  export NOTIFY_APPROVAL_MAX_SECONDS=1
  watch_hook
  wait_for_polls 1
  wait_quiet 2
  assert_no_watchers %w5
  look_away
  wait_quiet 0.5
  assert_not_called terminal-notifier
}

test_watch_slow_phase_still_notifies() {
  watch_setup %w6
  export NOTIFY_APPROVAL_POLLS=1
  export NOTIFY_APPROVAL_SLOW_INTERVAL=0.1
  watch_hook
  # Three polls: the fast phase is one poll long, so the rest are slow ones.
  wait_for_polls 3
  look_away
  wait_for_notifier
  assert_notifier_arg -title 'Cursor needs approval'
  assert_no_watchers %w6
  assert_notifier_calls 1
}

test_watch_hook_returns_while_watching() {
  watch_setup %w8
  SECONDS=0
  watch_hook
  [ "$SECONDS" -le 1 ] || { echo "hook took $SECONDS seconds" >&2; exit 1; }
  wait_for_polls 2
  wait_for_watchers %w8 1
  fake_set tmux-capture 'agent working'
  assert_no_watchers %w8
  assert_not_called terminal-notifier
}

# A pane id is data: it must not be read as a path or a printf format.
test_watch_odd_pane_id() {
  watch_setup '%s/../%d'
  watch_hook
  wait_for_polls 2
  [ "$(ls -A "$TMPDIR/tmux-agent-notify")" = 'pane--%s____%d' ] ||
    { echo "unexpected pane file: $(ls -A "$TMPDIR/tmux-agent-notify")" >&2; exit 1; }
  look_away
  wait_for_notifier
  assert_log_contains terminal-notifier "'%s/../%d'"
  assert_no_watchers '%s/../%d'
}

# The socket path is data too, of any length: the file name stays short and
# inside the directory.
test_watch_odd_socket() {
  local long name
  long=$(printf 'a%.0s' $(seq 1 300))
  watch_setup %w18
  export TMUX="/tmp/../é $long/../sock,1,0"
  watch_hook
  wait_for_polls 2
  name=$(ls -A "$TMPDIR/tmux-agent-notify")
  [ "$name" = "pane-${long:0:92}____sock-%w18" ] ||
    { echo "unexpected pane file: $name" >&2; exit 1; }
  [ "$(find "$TMPDIR" -type f | grep -c .)" = 1 ] ||
    { echo "files outside the directory: $(find "$TMPDIR" -type f)" >&2; exit 1; }
  look_away
  wait_for_notifier
  assert_no_watchers %w18
}

test_approval_wrapped_snippet_prefix() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=0
  export FAKE_OSA_NAME=Safari
  long_cmd='npm install very-long-package-name-that-wraps'
  export FAKE_TMUX_CAPTURE=$'Run this command?\nAllow once (y)\nnpm install very-long-\npackage-name-that-wraps'
  run_hook beforeShellExecution "$(printf '{"command":"%s","conversation_id":"c1"}' "$long_cmd")"
  wait_for_notifier
  assert_notifier_arg -title 'Cursor needs approval'
}

test_approval_command_is_not_run() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=0
  export FAKE_OSA_NAME=Safari
  local cmd="echo 'it' \$(touch $FAKE_LOG/ran)"
  export FAKE_TMUX_CAPTURE=$'Run this command?\n'"$cmd"
  run_hook beforeShellExecution "$(jq -nc --arg c "$cmd" '{command: $c, conversation_id: "c1"}')"
  assert_stdout_trimmed '{}'
  wait_for_notifier
  assert_notifier_arg -message "${cmd:0:79}…"
  if [ -e "$FAKE_LOG/ran" ]; then
    echo "command from hook input was executed" >&2
    exit 1
  fi
}

test_approval_bad_json() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=0
  export FAKE_TMUX_CAPTURE=$'agent working'
  run_hook beforeShellExecution 'not json'
  assert_exit 0
  assert_stdout_trimmed '{}'
  # No watcher was started: nothing reads the pane.
  wait_quiet 0.5
  assert_not_called terminal-notifier
  assert_log_lacks tmux 'capture-pane'
}

submit_json='{"prompt":"pick a color","conversation_id":"c1","workspace_roots":["/tmp/app"]}'
aborted_json='{"status":"aborted","conversation_id":"c1","workspace_roots":["/tmp/app"]}'
prompt_question=$'Clarifying Questions (1)\n› [ ] red\n  [ ] blue\n↑/↓ option · ←/→ question · Space select · Enter next/submit · Esc to skip\n→ Answer questions (Enter to select/next, Esc to skip)'

# The turn tests start with no card up and you looking at the pane, like
# watch_setup. turn_hook EVENT JSON runs a hook, not through run_capture.
turn_setup() {
  watch_setup "$1"
  fake_set tmux-capture $'agent working\nno card yet'
}

turn_hook() {
  "$ROOT/bin/notify" cursor "$1" <<<"$2" >"$FAKE_LOG/hook.stdout" ||
    { echo "hook $1 failed" >&2; exit 1; }
  [ "$(cat "$FAKE_LOG/hook.stdout")" = '{}' ] || { echo "hook $1 did not print {}" >&2; exit 1; }
}

# end_turn PANE: the turn ends; its watcher and the turn file go.
end_turn() {
  turn_hook stop "$aborted_json"
  assert_no_watchers "$1"
  [ -z "$(ls -A "$TMPDIR/tmux-agent-notify" 2>/dev/null)" ] ||
    { echo "file left behind: $(ls -A "$TMPDIR/tmux-agent-notify")" >&2; exit 1; }
}

# A question that is the first thing in the turn still notifies.
test_turn_question_notifies() {
  turn_setup %w19
  look_away
  turn_hook beforeSubmitPrompt "$submit_json"
  wait_for_captures 2
  assert_not_called terminal-notifier
  fake_set tmux-capture "$prompt_question"
  wait_for_notifier
  assert_notifier_arg -title 'Cursor has a question'
  assert_notifier_arg -message app
  assert_notifier_arg -group cursor-c1
  assert_log_contains terminal-notifier "'%w19'"
  end_turn %w19
  assert_notifier_calls 1
}

test_turn_looking_then_away() {
  turn_setup %w20
  fake_set tmux-capture "$prompt_question"
  turn_hook beforeSubmitPrompt "$submit_json"
  wait_for_polls 2
  assert_not_called terminal-notifier
  look_away
  wait_for_notifier
  end_turn %w20
  assert_notifier_calls 1
}

test_turn_one_notification_per_question() {
  local polls
  turn_setup %w21
  look_away
  fake_set tmux-capture "$prompt_question"
  turn_hook beforeSubmitPrompt "$submit_json"
  wait_for_notifier
  polls=$(tmux_calls capture-pane)
  wait_for_captures $((polls + 5))
  end_turn %w21
  assert_notifier_calls 1
}

test_turn_second_question_notifies_again() {
  local polls
  turn_setup %w22
  look_away
  fake_set tmux-capture "$prompt_question"
  turn_hook beforeSubmitPrompt "$submit_json"
  wait_for_notifier
  fake_set tmux-capture 'agent working'
  polls=$(tmux_calls capture-pane)
  wait_for_captures $((polls + 3))
  assert_notifier_calls 1
  fake_set tmux-capture "$prompt_question"
  wait_for_notifier_calls 2
  end_turn %w22
  assert_notifier_calls 2
}

# A narrow pane wraps the footer and leaves out the placeholder.
test_turn_wrapped_footer() {
  turn_setup %w23
  look_away
  fake_set tmux-capture $'Clarifying Questions (1)\n› [ ] red\n↑/↓ option · ←/→ question · Space select · Enter\nnext/submit ·  \nEsc to skip'
  turn_hook beforeSubmitPrompt "$submit_json"
  wait_for_notifier
  assert_notifier_arg -title 'Cursor has a question'
  end_turn %w23
}

# The card is still in the scrollback, above the last 15 lines.
test_turn_card_above_window() {
  local pad=$prompt_question i
  for i in $(seq 1 16); do
    pad=$pad$'\n'"pad-$i"
  done
  turn_setup %w24
  look_away
  fake_set tmux-capture "$pad"
  turn_hook beforeSubmitPrompt "$submit_json"
  wait_for_captures 5
  end_turn %w24
  assert_not_called terminal-notifier
}

# Each card is left to its own watcher.
test_turn_ignores_approval_card() {
  turn_setup %w25
  look_away
  fake_set tmux-capture "$prompt_shell"
  turn_hook beforeSubmitPrompt "$submit_json"
  wait_for_captures 5
  end_turn %w25
  assert_not_called terminal-notifier
}

test_approval_ignores_question_card() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=0
  export NOTIFY_APPROVAL_APPEAR_POLLS=3
  export FAKE_OSA_NAME=Safari
  export FAKE_TMUX_CAPTURE="$prompt_question"
  run_hook beforeShellExecution "$shell_json"
  wait_quiet 1
  assert_not_called terminal-notifier
}

# The turn watcher never takes the pane, so an approval watcher is not stopped.
test_turn_keeps_approval_watcher() {
  watch_setup %w26
  turn_hook beforeSubmitPrompt "$submit_json"
  watch_hook
  wait_for_polls 2
  wait_for_watchers %w26 2
  look_away
  wait_for_notifier
  wait_for_watchers %w26 1
  end_turn %w26
  assert_notifier_calls 1
  assert_notifier_arg -title 'Cursor needs approval'
}

test_turn_ends_on_stop() {
  turn_setup %w27
  look_away
  turn_hook beforeSubmitPrompt "$submit_json"
  wait_for_captures 2
  end_turn %w27
  fake_set tmux-capture "$prompt_question"
  wait_quiet 0.5
  assert_not_called terminal-notifier
}

# The turn file is written by the hook, so a turn that ends before its watcher
# has polled once still stops it.
test_turn_ended_before_watcher_polls() {
  turn_setup %w28
  turn_hook beforeSubmitPrompt "$submit_json"
  turn_hook stop "$aborted_json"
  assert_no_watchers %w28
}

test_turn_newer_replaces_older() {
  turn_setup %w29
  turn_hook beforeSubmitPrompt "$submit_json"
  wait_for_captures 2
  turn_hook beforeSubmitPrompt "$submit_json"
  wait_for_watchers %w29 1
  look_away
  fake_set tmux-capture "$prompt_question"
  wait_for_notifier
  wait_quiet 0.5
  end_turn %w29
  assert_notifier_calls 1
}

# agent_setup: the hook runs under process 500, a child of the pane's shell
# 900, which started at the time given. turn_hook runs the hook straight from
# this shell, so this shell is its parent. Bash 3.2 has no BASHPID.
agent_setup() {
  local me
  me=$(exec sh -c 'echo $PPID')
  fake_set tmux-pane-pid 900
  fake_set ps-list "  $me   500 Tue Oct 13 11:05:00 2026
  500   900 Tue Oct 13 11:00:00 2026
  900     1 Tue Oct 13 10:00:00 2026    "
  # ps pads the start time.
  fake_set ps-start-500 'Tue Oct 13 11:00:00 2026    '
}

# The agent dies without a stop hook: the watcher goes too.
test_turn_ends_when_agent_exits() {
  turn_setup %w31
  agent_setup
  look_away
  turn_hook beforeSubmitPrompt "$submit_json"
  wait_for_captures 2
  wait_for_watchers %w31 1
  assert_log_contains ps "-o lstart= -p 500"
  rm -f "$FAKE_STATE/ps-start-500"
  assert_no_watchers %w31
  fake_set tmux-capture "$prompt_question"
  wait_quiet 0.5
  assert_not_called terminal-notifier
}

# The id now belongs to a process that started later.
test_turn_agent_id_reused() {
  turn_setup %w32
  agent_setup
  fake_set ps-start-500 'Tue Oct 13 12:00:00 2026'
  turn_hook beforeSubmitPrompt "$submit_json"
  assert_no_watchers %w32
}

# With the agent alive, the turn has no time limit.
test_turn_agent_alive_outlasts_budget() {
  turn_setup %w33
  agent_setup
  export NOTIFY_TURN_MAX_SECONDS=1
  look_away
  turn_hook beforeSubmitPrompt "$submit_json"
  wait_quiet 2
  wait_for_watchers %w33 1
  fake_set tmux-capture "$prompt_question"
  wait_for_notifier
  end_turn %w33
}

# No agent process found: the budget ends the watcher.
test_turn_without_agent_uses_budget() {
  turn_setup %w34
  export NOTIFY_TURN_MAX_SECONDS=1
  turn_hook beforeSubmitPrompt "$submit_json"
  wait_for_captures 1
  assert_no_watchers %w34
  assert_log_contains tmux-pane-pid pane_pid
}

# Ending the turn does not change the finished notification.
test_turn_stop_completed_still_notifies() {
  turn_setup %w30
  turn_hook beforeSubmitPrompt "$submit_json"
  wait_for_captures 2
  look_away
  turn_hook stop '{"status":"completed","conversation_id":"c1","workspace_roots":["/tmp/app"]}'
  assert_no_watchers %w30
  wait_for_notifier
  assert_notifier_arg -title 'Cursor finished'
  assert_notifier_calls 1
}

run_tests \
  test_turn_question_notifies \
  test_turn_looking_then_away \
  test_turn_one_notification_per_question \
  test_turn_second_question_notifies_again \
  test_turn_wrapped_footer \
  test_turn_card_above_window \
  test_turn_ignores_approval_card \
  test_approval_ignores_question_card \
  test_turn_keeps_approval_watcher \
  test_turn_ends_on_stop \
  test_turn_ended_before_watcher_polls \
  test_turn_newer_replaces_older \
  test_turn_stop_completed_still_notifies \
  test_turn_ends_when_agent_exits \
  test_turn_agent_id_reused \
  test_turn_agent_alive_outlasts_budget \
  test_turn_without_agent_uses_budget \
  test_approval_command_is_not_run \
  test_approval_bad_json \
  test_approval_no_pane \
  test_approval_no_prompt \
  test_approval_shell_notifies \
  test_approval_mcp_notifies \
  test_approval_stale_prompt_skipped \
  test_approval_short_snippet_ok \
  test_approval_visible_pane_silent \
  test_approval_wrapped_snippet_prefix \
  test_approval_returns_before_delay \
  test_approval_other_command_silent \
  test_approval_body_is_folder_without_detail \
  test_approval_long_body_cut \
  test_approval_non_object_payload \
  test_watch_look_then_away \
  test_watch_answered_then_away \
  test_watch_pane_gone \
  test_watch_second_replaces_first \
  test_watch_other_command_keeps_first \
  test_watch_same_pane_other_server \
  test_watch_one_miss_keeps_watching \
  test_watch_bad_interval \
  test_watch_bad_max_seconds \
  test_watch_card_appears_later \
  test_watch_card_never_appears \
  test_watch_card_above_window \
  test_watch_fast_then_slow \
  test_watch_budget_reached \
  test_watch_slow_phase_still_notifies \
  test_watch_hook_returns_while_watching \
  test_watch_odd_pane_id \
  test_watch_odd_socket
