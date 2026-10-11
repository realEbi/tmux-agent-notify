#!/usr/bin/env bash
set -u
source "$(dirname "$0")/harness.sh"

# run_hook EVENT JSON
# For hooks that start no watcher, or whose watcher is not looked at. The
# hook's parent is this test, which the fake ps knows nothing about, so the
# hook's own environment is used.
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
  run_capture "$ROOT/bin/notify" codex "$event" <<<"$json"
}

# Payloads as sent by Codex CLI 0.162.1, with shorter ids and paths.
stop_json='{"session_id":"s1","turn_id":"t1","transcript_path":"/tmp/rollout.jsonl","cwd":"/tmp/app","hook_event_name":"Stop","model":"gpt-6-astra","permission_mode":"default","stop_hook_active":false,"last_assistant_message":"done"}'
shell_json='{"session_id":"s1","turn_id":"t1","transcript_path":"/tmp/rollout.jsonl","cwd":"/tmp/app","hook_event_name":"PermissionRequest","model":"gpt-6-astra","permission_mode":"default","tool_name":"Bash","tool_input":{"command":"echo hi > b.txt","description":"May I write b.txt as requested? The workspace is read-only."}}'
patch_json='{"session_id":"s1","turn_id":"t2","transcript_path":"/tmp/rollout.jsonl","cwd":"/tmp/app","hook_event_name":"PermissionRequest","model":"gpt-6-astra","permission_mode":"default","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Update File: /tmp/app/a.txt\n@@\n hello\n+world\n*** End Patch"}}'
interrupt_json='{"session_id":"s1","turn_id":"t2","transcript_path":"/tmp/rollout.jsonl","cwd":"/tmp/app","hook_event_name":"Interrupt","model":"gpt-6-astra","permission_mode":"default"}'

# Pane text captured from Codex CLI 0.162.1 in a pane 110 columns wide. Only
# the folder paths were shortened.
pane_shell=$(cat "$HARNESS_DIR/fixtures/codex-shell-prompt.txt")
pane_edit=$(cat "$HARNESS_DIR/fixtures/codex-edit-prompt.txt")
pane_working=$(cat "$HARNESS_DIR/fixtures/codex-working.txt")
pane_idle=$'Token usage: total=11,470 input=11,323 (+ 62,080 cached) output=147\nTo continue this session, run:\n  codex resume s1\nOr run codex resume and select Run shell command.\n➜  proj git:(main) ✗'

DAEMON='/opt/codex/bin/codex app-server --listen unix:///tmp/codex/daemon.sock --managed-daemon'
CLIENT=/opt/codex/bin/codex

# as_child_of COMMAND HOOK...
# Run HOOK as the child of a process whose command line, as the fake ps tells
# it, is COMMAND. The process id is kept in FAKE_STATE/parent-pid.
as_child_of() {
  bash -c '
    printf "%s" "$1" > "$FAKE_STATE/ps-command-$$"
    printf "%s" "$$" > "$FAKE_STATE/parent-pid"
    shift
    "$@"
    exit $?
  ' _ "$@"
}

# daemon_hook EVENT JSON
# The hook as the Codex daemon runs it. Not for hooks that start a watcher.
daemon_hook() {
  run_capture as_child_of "$DAEMON" "$ROOT/bin/notify" codex "$1" <<<"$2"
}

# add_process PID TTY COMMAND DIR [ENVIRONMENT]
# Make the fake ps and lsof show one more process.
PS_LIST=
add_process() {
  PS_LIST="$PS_LIST$(printf '%5s %-8s %s' "$1" "$2" "$3")"$'\n'
  fake_set ps-list "$PS_LIST"
  fake_set "lsof-cwd-$1" "$4"
  fake_set "ps-env-$1" "$3${5:+ $5}"
}

# Hook environment of pane A, and a session in pane B: another tmux server and
# another terminal app.
ENV_B='HOME=/Users/me TMUX=/tmp/sockB,77,3 TERM=tmux-256color TMUX_PANE=%712 SHELL=/bin/zsh __CFBundleIdentifier=com.mitchellh.ghostty LANG=en_US.UTF-8'
use_pane_a() {
  PS_LIST=
  export TMUX=/tmp/sockA,1,0 TMUX_PANE=%711 __CFBundleIdentifier=com.apple.Terminal
  add_process 1 '??' /sbin/launchd /
  add_process 4001 '??' "$DAEMON" /
}

# The watcher tests start with you looking at the pane and an approval on
# screen. watch_setup PANE sets that scene; a test may change it before
# watch_hook starts the watcher. The time budget is far longer than any test
# waits, so a watcher that exits did so for the reason under test.
watch_setup() {
  harness_use_fakes
  export TMUX_PANE=$1
  harness_track_pane "$1"
  export __CFBundleIdentifier=com.apple.Terminal
  fake_set osa-bundle com.apple.Terminal
  fake_set tmux-display '1 1 1'
  fake_set tmux-capture "$pane_shell"
  export NOTIFY_APPROVAL_DELAY=0.1
  export NOTIFY_APPROVAL_INTERVAL=0.1
  export NOTIFY_APPROVAL_POLLS=1000
  export NOTIFY_APPROVAL_SLOW_INTERVAL=0.1
  export NOTIFY_APPROVAL_MAX_SECONDS=30
}

# watch_hook [JSON]
# Not through run_capture: bash waits for orphaned workers inside $().
# HOOK_PARENT, when set, is the command line of the hook's parent.
watch_hook() {
  local status=0
  if [ -n "${HOOK_PARENT-}" ]; then
    as_child_of "$HOOK_PARENT" "$ROOT/bin/notify" codex PermissionRequest <<<"${1-$shell_json}" >"$FAKE_LOG/hook.stdout" || status=$?
  else
    "$ROOT/bin/notify" codex PermissionRequest <<<"${1-$shell_json}" >"$FAKE_LOG/hook.stdout" || status=$?
  fi
  [ "$status" = 0 ] || { echo "hook exited with $status" >&2; exit 1; }
  [ "$(cat "$FAKE_LOG/hook.stdout")" = '{}' ] || { echo "hook did not print {}" >&2; exit 1; }
}

look_away() {
  fake_set osa-bundle com.example.Other
}

expect_silent() {
  assert_exit 0
  assert_not_called terminal-notifier
  assert_not_called osascript
  assert_stdout_trimmed '{}'
}

# click_for BUNDLE SOCKET PANE
# The command a click on the notification runs.
click_for() {
  printf "'%s' '%s' '%s' '%s'" "$ROOT/bin/focus-pane" "$1" "$2" "$3"
}

# parsed EVENT JSON
# Print kind, title and detail as the adapter reads them.
parsed() {
  (
    . "$ROOT/bin/agents/codex.sh"
    agent_parse "$1" "$2"
    printf '%s|%s|%s\n' "$kind" "$title" "$detail"
  )
}

assert_parsed() {
  local got
  got=$(parsed PermissionRequest "$1")
  [ "$got" = "attention|Codex needs approval|$2" ] || { echo "parsed [$1]: got [$got], want detail [$2]" >&2; exit 1; }
}

# on_screen TEXT
on_screen() {
  (
    . "$ROOT/bin/agents/codex.sh"
    agent_prompt_on_screen "$1" ''
  )
}

test_codex_adapter_values() {
  harness_use_fakes
  local got want
  got=$(
    . "$ROOT/bin/agents/codex.sh"
    printf '%s|%s|%s|%s\n' "$AGENT_LABEL" "$AGENT_PROMPT_APPEARS_LATER" "$AGENT_CONFIG" "$AGENT_CONFIG_SHAPE"
    agent_hooks
    declare -F agent_locate
  )
  want=$'Codex|1|.codex/hooks.json|nested\nStop\t\nPermissionRequest\t\nagent_locate'
  [ "$got" = "$want" ] || { echo "adapter values: got [$got]" >&2; exit 1; }
}

test_codex_stop() {
  harness_use_fakes
  export TMUX=/tmp/sock,1,0
  run_hook Stop "$stop_json"
  assert_exit 0
  assert_stdout_trimmed '{}'
  assert_notifier_calls 1
  assert_notifier_arg -title 'Codex finished'
  assert_notifier_arg -message app
  assert_notifier_arg -group codex-s1
  assert_notifier_arg -execute "$(click_for '' /tmp/sock %12)"
  assert_log_lacks tmux 'capture-pane'
}

test_codex_stop_while_looking() {
  harness_use_fakes
  export __CFBundleIdentifier=com.apple.Terminal
  fake_set osa-bundle com.apple.Terminal
  fake_set tmux-display '1 1 1'
  run_hook Stop "$stop_json"
  assert_exit 0
  assert_stdout_trimmed '{}'
  assert_not_called terminal-notifier
  # The hook got as far as the pane check.
  [ "$(tmux_calls display-message)" = 1 ] ||
    { echo "expected one pane check, saw $(tmux_calls display-message)" >&2; exit 1; }
}

test_codex_shell_prompt_away() {
  watch_setup %701
  export TMUX=/tmp/sock,1,0
  look_away
  watch_hook
  wait_for_notifier
  assert_notifier_arg -title 'Codex needs approval'
  assert_notifier_arg -message 'echo hi > b.txt'
  assert_notifier_arg -group codex-s1
  assert_notifier_arg -execute "$(click_for com.apple.Terminal /tmp/sock %701)"
  assert_no_watchers %701
  assert_notifier_calls 1
}

test_codex_edit_prompt_away() {
  watch_setup %702
  fake_set tmux-capture "$pane_edit"
  look_away
  watch_hook "$patch_json"
  wait_for_notifier
  assert_notifier_arg -title 'Codex needs approval'
  assert_notifier_arg -message 'Edit a.txt'
  assert_notifier_arg -group codex-s1
  assert_no_watchers %702
  assert_notifier_calls 1
}

test_codex_detail() {
  harness_use_fakes
  assert_parsed "$shell_json" 'echo hi > b.txt'
  assert_parsed "$patch_json" 'Edit a.txt'
  # Only the first line of a command, and the first file of a patch.
  assert_parsed '{"tool_name":"Bash","tool_input":{"command":"make test\nmake install"}}' 'make test'
  assert_parsed '{"tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Add File: src/new file.c\n+x\n*** Delete File: old.c\n*** End Patch"}}' 'Edit new file.c'
  assert_parsed '{"tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** End Patch"}}' 'Edit files'
  assert_parsed '{"tool_name":"apply_patch","tool_input":{}}' 'Edit files'
  # Other tools are shown by name.
  assert_parsed '{"tool_name":"mcp__github__create_issue","tool_input":{"title":"x"}}' 'mcp__github__create_issue'
  assert_parsed '{"tool_name":"mcp__x__y"}' 'mcp__x__y'
  assert_parsed '{"tool_name":"mcp__x__y","tool_input":"text"}' 'mcp__x__y'
  assert_parsed '{"tool_name":"Bash","tool_input":{"command":["ls","-l"]}}' 'ls -l'
  assert_parsed '{"tool_name":7,"tool_input":{"command":7}}' ''

  local got
  got=$(parsed Stop "$stop_json")
  [ "$got" = 'finished|Codex finished|' ] || { echo "Stop: got [$got]" >&2; exit 1; }
  got=$(parsed Interrupt "$interrupt_json")
  [ "$got" = '||' ] || { echo "Interrupt: got [$got]" >&2; exit 1; }
}

# The core cuts a long command to 80 characters.
test_codex_long_command() {
  watch_setup %703
  look_away
  local cmd json
  cmd=$(printf 'echo %0100d' 7)
  json=$(jq -nc --arg c "$cmd" '{session_id: "s1", cwd: "/tmp/app", tool_name: "Bash", tool_input: {command: $c}}')
  watch_hook "$json"
  wait_for_notifier
  assert_notifier_arg -message "${cmd:0:79}…"
  assert_no_watchers %703
}

test_codex_look_then_away() {
  watch_setup %704
  watch_hook
  wait_for_polls 2
  assert_not_called terminal-notifier
  look_away
  wait_for_notifier
  assert_notifier_arg -title 'Codex needs approval'
  assert_notifier_arg -message 'echo hi > b.txt'
  assert_no_watchers %704
  assert_notifier_calls 1
}

test_codex_answered_then_away() {
  watch_setup %705
  watch_hook
  wait_for_polls 2
  fake_set tmux-capture "$pane_working"
  # The watcher is gone before you look away, so nothing is left to notify.
  assert_no_watchers %705
  look_away
  wait_quiet 0.5
  assert_not_called terminal-notifier
}

# The hook runs before the approval screen is drawn.
test_codex_prompt_appears_later() {
  watch_setup %706
  fake_set tmux-capture "$pane_working"
  look_away
  watch_hook
  wait_for_captures 3
  assert_not_called terminal-notifier
  wait_for_watchers %706 1
  fake_set tmux-capture "$pane_shell"
  wait_for_notifier
  assert_no_watchers %706
  assert_notifier_calls 1
}

test_codex_prompt_never_appears() {
  watch_setup %707
  export NOTIFY_APPROVAL_APPEAR_POLLS=3
  fake_set tmux-capture "$pane_working"
  look_away
  watch_hook
  assert_no_watchers %707
  assert_not_called terminal-notifier
  [ "$(tmux_calls capture-pane)" = 3 ] ||
    { echo "expected three capture-pane calls, saw $(tmux_calls capture-pane)" >&2; exit 1; }
}

test_codex_prompt_on_screen() {
  harness_use_fakes
  on_screen "$pane_shell" || { echo "shell prompt not recognized" >&2; exit 1; }
  on_screen "$pane_edit" || { echo "edit prompt not recognized" >&2; exit 1; }
  # A pane taller than its text ends in empty lines, and some hold only spaces.
  on_screen "$pane_shell"$'\n\n   \n \t \n\n' || { echo "trailing blank lines" >&2; exit 1; }
  # A narrow pane wraps the line; the third line from the bottom still counts.
  on_screen $'  3. No (esc)\n\n  Press enter to confirm or esc to cancel and\n  more\n  words' ||
    { echo "third line from the bottom" >&2; exit 1; }
  if on_screen "$pane_working"; then echo "working pane taken for a prompt" >&2; exit 1; fi
  if on_screen "$pane_idle"; then echo "idle pane taken for a prompt" >&2; exit 1; fi
  if on_screen ''; then echo "empty pane taken for a prompt" >&2; exit 1; fi
  # The words in the conversation, four lines that are not blank from the bottom.
  if on_screen $'• Press enter to confirm or esc to cancel\n\n• Working (5s • esc to interrupt)\n» Ask Codex to do anything\n  ? for shortcuts'; then
    echo "words in the conversation taken for a prompt" >&2
    exit 1
  fi
}

test_codex_unknown_event() {
  local event
  # Interrupt is what Codex sends for a turn you stop; it is not hooked. Event
  # names are matched exactly, as Codex spells them.
  for event in Interrupt PreToolUse stop permissionrequest ''; do
    harness_use_fakes
    run_hook "$event" "$shell_json"
    expect_silent
    assert_not_called tmux
    assert_not_called ps
    assert_not_called lsof
  done
}

test_codex_bad_json() {
  local event json
  for event in Stop PermissionRequest; do
    for json in 'not json' '' '[]' 'null' '"Bash"' '{"tool_name":'; do
      harness_use_fakes
      daemon_hook "$event" "$json"
      expect_silent
      assert_not_called tmux
      assert_not_called ps
      # No watcher was started: nothing reads the pane later either.
      if [ "$event" = PermissionRequest ]; then
        wait_quiet 0.3
        assert_not_called terminal-notifier
        assert_not_called tmux
      fi
    done
  done
}

test_codex_no_session_no_cwd() {
  harness_use_fakes
  run_hook Stop '{"hook_event_name":"Stop"}'
  assert_notifier_arg -title 'Codex finished'
  assert_notifier_arg -message agent
  assert_notifier_arg -group codex-unknown

  harness_use_fakes
  run_hook Stop '{"session_id":7,"cwd":7}'
  assert_notifier_arg -message agent
  assert_notifier_arg -group codex-unknown

  # With no cwd there is nothing to look a session up by.
  harness_use_fakes
  use_pane_a
  add_process 4102 ttys004 "$CLIENT" '' "$ENV_B"
  daemon_hook Stop '{"session_id":"s1"}'
  assert_notifier_calls 1
  assert_notifier_arg -execute "$(click_for com.apple.Terminal /tmp/sockA %711)"
  assert_not_called lsof
}

# Outside tmux, and not run by the daemon: nothing to notify about.
test_codex_no_pane() {
  local event
  for event in Stop PermissionRequest; do
    harness_use_fakes
    KEEP_PANE_UNSET=1
    run_hook "$event" "$shell_json"
    expect_silent
    assert_not_called tmux
  done

  harness_use_fakes
  export TMUX_PANE=
  run_hook PermissionRequest "$shell_json"
  expect_silent
  assert_not_called tmux
}

# The daemon's environment names pane A. The session for the payload's folder
# runs in pane B, so everything is about B.
test_codex_daemon_other_pane() {
  harness_use_fakes
  use_pane_a
  add_process 4102 ttys004 "$CLIENT" /tmp/app "$ENV_B"

  # B's terminal is in front and B is visible: you are looking.
  fake_set osa-bundle com.mitchellh.ghostty
  fake_set tmux-display '1 1 1'
  daemon_hook Stop "$stop_json"
  assert_exit 0
  assert_stdout_trimmed '{}'
  assert_not_called terminal-notifier
  [ "$(cat "$FAKE_LOG/tmux")" = $'-S\n/tmp/sockB\ndisplay-message\n-p\n-t\n%712\n#{pane_active} #{window_active} #{session_attached}' ] ||
    { echo "unexpected tmux calls:" >&2; cat "$FAKE_LOG/tmux" >&2; exit 1; }
  # The locator asked about the hook's own parent, then looked for sessions.
  [ "$(cat "$FAKE_LOG/ps")" = "-o command= -p $(cat "$FAKE_STATE/parent-pid")"$'\n-axo pid=,tty=,command=\neww -o command= -p 4102' ] ||
    { echo "unexpected ps calls:" >&2; cat "$FAKE_LOG/ps" >&2; exit 1; }
  assert_log_line lsof '-a -d cwd -p 4102 -Fpn'

  # A's terminal is in front: you are not looking at B.
  fake_set osa-bundle com.apple.Terminal
  daemon_hook Stop "$stop_json"
  assert_exit 0
  assert_stdout_trimmed '{}'
  assert_notifier_calls 1
  assert_notifier_arg -title 'Codex finished'
  assert_notifier_arg -message app
  assert_notifier_arg -execute "$(click_for com.mitchellh.ghostty /tmp/sockB %712)"

  # B's terminal is in front, but B is not the active pane.
  fake_set osa-bundle com.mitchellh.ghostty
  fake_set tmux-display '0 1 1'
  daemon_hook Stop "$stop_json"
  assert_notifier_calls 2
  assert_notifier_arg -execute "$(click_for com.mitchellh.ghostty /tmp/sockB %712)" 2
  assert_log_lacks tmux /tmp/sockA
  assert_log_lacks tmux %711
  assert_log_lacks terminal-notifier %711
}

# The watcher reads, claims and reports pane B too.
test_codex_daemon_watcher_other_pane() {
  watch_setup %712
  harness_track_pane %711
  use_pane_a
  add_process 4102 ttys004 "$CLIENT" /tmp/app "$ENV_B"
  HOOK_PARENT=$DAEMON
  fake_set osa-bundle com.mitchellh.ghostty
  watch_hook
  wait_for_polls 2
  assert_not_called terminal-notifier
  wait_for_watchers %712 1
  [ "$(ls -A "$TMPDIR/tmux-agent-notify")" = 'pane-_tmp_sockB-%712' ] ||
    { echo "unexpected pane file: $(ls -A "$TMPDIR/tmux-agent-notify")" >&2; exit 1; }
  # Bringing A's terminal to the front is looking away from B.
  fake_set osa-bundle com.apple.Terminal
  wait_for_notifier
  assert_notifier_arg -title 'Codex needs approval'
  assert_notifier_arg -message 'echo hi > b.txt'
  assert_notifier_arg -execute "$(click_for com.mitchellh.ghostty /tmp/sockB %712)"
  assert_no_watchers %712
  assert_no_watchers %711
  assert_notifier_calls 1
  assert_log_contains tmux capture-pane
  assert_log_contains tmux /tmp/sockB
  assert_log_lacks tmux /tmp/sockA
  assert_log_lacks tmux %711
}

# A daemon started outside tmux has no TMUX_PANE at all.
test_codex_daemon_no_pane_in_hook() {
  harness_use_fakes
  PS_LIST=
  add_process 4102 ttys004 "$CLIENT" /tmp/app "$ENV_B"
  daemon_hook Stop "$stop_json"
  assert_exit 0
  assert_stdout_trimmed '{}'
  assert_notifier_calls 1
  assert_notifier_arg -execute "$(click_for com.mitchellh.ghostty /tmp/sockB %712)"

  watch_setup %712
  unset TMUX_PANE __CFBundleIdentifier
  PS_LIST=
  add_process 4102 ttys004 "$CLIENT" /tmp/app "$ENV_B"
  HOOK_PARENT=$DAEMON
  look_away
  watch_hook
  wait_for_notifier
  assert_notifier_arg -execute "$(click_for com.mitchellh.ghostty /tmp/sockB %712)"
  assert_no_watchers %712
  assert_notifier_calls 1
}

# No session in the payload's folder: the hook's own environment is all there is.
test_codex_daemon_no_match() {
  harness_use_fakes
  use_pane_a
  add_process 4102 ttys004 "$CLIENT" /tmp/other "$ENV_B"
  daemon_hook Stop "$stop_json"
  assert_notifier_calls 1
  assert_notifier_arg -execute "$(click_for com.apple.Terminal /tmp/sockA %711)"
  assert_log_line lsof '-a -d cwd -p 4102 -Fpn'

  # No session at all.
  harness_use_fakes
  use_pane_a
  daemon_hook Stop "$stop_json"
  assert_notifier_calls 1
  assert_notifier_arg -execute "$(click_for com.apple.Terminal /tmp/sockA %711)"
  assert_not_called lsof

  # Neither a session nor a pane of the hook's own.
  harness_use_fakes
  daemon_hook Stop "$stop_json"
  expect_silent
  assert_not_called tmux
}

# With codex --no-daemon the parent is the session itself, and the hook's
# environment is right. A session elsewhere in the same folder is not asked.
test_codex_parent_is_session() {
  local parent
  for parent in "$CLIENT --no-daemon" "$CLIENT" '/bin/zsh -c app-server' ''; do
    harness_use_fakes
    use_pane_a
    add_process 4102 ttys004 "$CLIENT" /tmp/app "$ENV_B"
    run_capture as_child_of "$parent" "$ROOT/bin/notify" codex Stop <<<"$stop_json"
    assert_exit 0
    assert_stdout_trimmed '{}'
    assert_notifier_calls 1
    assert_notifier_arg -execute "$(click_for com.apple.Terminal /tmp/sockA %711)"
    assert_log_line ps "-o command= -p $(cat "$FAKE_STATE/parent-pid")"
    assert_log_lacks ps axo
    assert_log_lacks ps eww
    assert_not_called lsof
  done
}

# Only a codex process in a terminal counts, and only in the payload's folder.
test_codex_picks_session_by_folder() {
  harness_use_fakes
  use_pane_a
  local wrong='TMUX=/tmp/sockC,5,0 TMUX_PANE=%713 __CFBundleIdentifier=com.example.Wrong'
  # The daemon itself, a codex without a terminal, and other programs.
  add_process 4002 ttys001 "$DAEMON" /tmp/app "$wrong"
  add_process 4003 '??' "$CLIENT exec task" /tmp/app "$wrong"
  add_process 4004 ttys002 'vim codex' /tmp/app "$wrong"
  add_process 4005 ttys002 "$ROOT/bin/notify codex Stop" /tmp/app "$wrong"
  add_process 4006 ttys002 '/opt/codex/bin/codex-helper' /tmp/app "$wrong"
  # Sessions in other folders.
  add_process 4101 ttys003 "$CLIENT" /tmp/app/sub "$wrong"
  add_process 4103 ttys005 "node /opt/homebrew/bin/codex resume" /tmp "$wrong"
  # The one, then a second session in the same folder: the first is taken.
  add_process 4102 ttys004 "$CLIENT --model gpt-6-astra" /tmp/app "$ENV_B"
  add_process 4104 ttys006 codex /tmp/app "$wrong"
  daemon_hook Stop "$stop_json"
  assert_notifier_calls 1
  assert_notifier_arg -execute "$(click_for com.mitchellh.ghostty /tmp/sockB %712)"
  assert_log_line lsof '-a -d cwd -p 4101,4103,4102,4104 -Fpn'
  assert_log_line ps 'eww -o command= -p 4102'
  assert_log_lacks ps 'eww -o command= -p 4104'
}

# /tmp is /private/tmp on macOS, and a trailing slash means nothing.
test_codex_folder_spelling() {
  local real json
  harness_use_fakes
  use_pane_a
  real=$(cd /tmp && pwd -P)
  add_process 4102 ttys004 "$CLIENT" "$real" "$ENV_B"
  json=$(jq -nc '{session_id: "s1", cwd: "/tmp/"}')
  daemon_hook Stop "$json"
  assert_notifier_calls 1
  assert_notifier_arg -execute "$(click_for com.mitchellh.ghostty /tmp/sockB %712)"

  # A folder that is gone is compared as text, without trailing slashes.
  harness_use_fakes
  use_pane_a
  add_process 4102 ttys004 "$CLIENT" /nonexistent/app// "$ENV_B"
  json=$(jq -nc '{session_id: "s1", cwd: "/nonexistent/app/"}')
  daemon_hook Stop "$json"
  assert_notifier_calls 1
  assert_notifier_arg -execute "$(click_for com.mitchellh.ghostty /tmp/sockB %712)"
}

# The session's environment is read word by word.
test_codex_session_environment() {
  # Names that only look alike are not taken, and arguments with spaces do no harm.
  harness_use_fakes
  use_pane_a
  add_process 4102 ttys004 "$CLIENT -c note=a b" /tmp/app \
    'XTMUX=/x,1,1 TMUX_PANE_OLD=%9 TMUX=/tmp/sockB,77,3 MY__CFBundleIdentifier=no TMUX_PANE=%712 TMUX_PANES=%8 __CFBundleIdentifier=com.mitchellh.ghostty TMUXX=1'
  daemon_hook Stop "$stop_json"
  assert_notifier_calls 1
  assert_notifier_arg -execute "$(click_for com.mitchellh.ghostty /tmp/sockB %712)"

  # A session that is not in tmux gets no notification, whatever the daemon's
  # environment says.
  harness_use_fakes
  use_pane_a
  add_process 4102 ttys004 "$CLIENT" /tmp/app 'HOME=/Users/me __CFBundleIdentifier=com.mitchellh.ghostty'
  daemon_hook Stop "$stop_json"
  expect_silent
  assert_not_called tmux

  # Values that do not look like a tmux socket and pane id are not used.
  local bad
  for bad in 'TMUX=/tmp/sockB,77,3 TMUX_PANE=712' 'TMUX=/tmp/sockB,77,3 TMUX_PANE=%' \
    'TMUX=sockB TMUX_PANE=%712' 'TMUX_PANE=%712' 'TMUX=/tmp/my TMUX_PANE=%712'; do
    harness_use_fakes
    use_pane_a
    add_process 4102 ttys004 "$CLIENT" /tmp/app "$bad"
    daemon_hook Stop "$stop_json"
    expect_silent
    assert_not_called tmux
  done

  # No terminal app known: the front app is checked by name, as elsewhere.
  harness_use_fakes
  use_pane_a
  add_process 4102 ttys004 "$CLIENT" /tmp/app 'TMUX=/tmp/sockB,77,3 TMUX_PANE=%712'
  daemon_hook Stop "$stop_json"
  assert_notifier_calls 1
  assert_notifier_arg -execute "$(click_for '' /tmp/sockB %712)"
  assert_log_contains osascript 'name of first application process'
}

# ps or lsof missing or failing: the hook's own environment, and still {}.
test_codex_locator_tools_fail() {
  local tool
  for tool in ps lsof; do
    harness_use_fakes
    use_pane_a
    add_process 4102 ttys004 "$CLIENT" /tmp/app "$ENV_B"
    harness_hide "$tool"
    daemon_hook Stop "$stop_json"
    assert_exit 0
    assert_stdout_trimmed '{}'
    assert_notifier_calls 1
    assert_notifier_arg -execute "$(click_for com.apple.Terminal /tmp/sockA %711)"
  done

  # The session ended between the two looks at it.
  harness_use_fakes
  use_pane_a
  add_process 4102 ttys004 "$CLIENT" /tmp/app "$ENV_B"
  /bin/rm "$FAKE_STATE/ps-env-4102"
  daemon_hook Stop "$stop_json"
  assert_notifier_calls 1
  assert_notifier_arg -execute "$(click_for com.apple.Terminal /tmp/sockA %711)"
}

# What ps and lsof print is data.
test_codex_process_text_is_not_run() {
  harness_use_fakes
  use_pane_a
  cd "$FAKE_LOG" || exit 1
  add_process 4100 ttys003 "$CLIENT \$(touch ran) \`touch ran\` *" "\$(touch ran)" "$ENV_B"
  add_process 4102 ttys004 "$CLIENT \$(touch ran) ; touch ran" /tmp/app \
    "A=\$(touch ran) * TMUX=/tmp/sockB,77,3 TMUX_PANE=%712 __CFBundleIdentifier=it's\`touch\${IFS}ran\`"
  daemon_hook Stop "$stop_json"
  assert_notifier_calls 1
  assert_notifier_arg -execute "'$ROOT/bin/focus-pane' 'it'\\''s\`touch\${IFS}ran\`' '/tmp/sockB' '%712'"
  if [ -e "$FAKE_LOG/ran" ]; then
    echo "text from ps or lsof was executed" >&2
    exit 1
  fi
}

# Cursor and Claude Code have no locator: no process is looked at, even when
# the hook's parent looks like the daemon.
test_other_agents_do_not_locate() {
  watch_setup %714
  use_pane_a
  export TMUX_PANE=%714
  add_process 4102 ttys004 "$CLIENT" /tmp/app "$ENV_B"
  look_away
  fake_set tmux-capture $' Do you want to proceed?\n ❯ 1. Yes\n\n Esc to cancel · Tab to amend'
  run_capture as_child_of "$DAEMON" "$ROOT/bin/notify" claude Stop <<<"$stop_json"
  assert_stdout_trimmed '{}'
  run_capture as_child_of "$DAEMON" "$ROOT/bin/notify" cursor stop <<<'{"status":"completed","conversation_id":"c1","workspace_roots":["/tmp/app"]}'
  assert_stdout_trimmed '{}'
  as_child_of "$DAEMON" "$ROOT/bin/notify" claude Notification >/dev/null \
    <<<'{"session_id":"s1","cwd":"/tmp/app","notification_type":"permission_prompt"}'
  wait_for_notifier_calls 3
  assert_no_watchers %714
  assert_notifier_arg -title 'Claude finished' 1
  assert_notifier_arg -title 'Cursor finished' 2
  assert_notifier_arg -title 'Claude is waiting for you' 3
  assert_notifier_arg -execute "$(click_for com.apple.Terminal /tmp/sockA %714)" 3
  assert_not_called ps
  assert_not_called lsof
  assert_log_lacks tmux /tmp/sockB

  # And without a pane they stay silent, as before.
  harness_use_fakes
  add_process 4102 ttys004 "$CLIENT" /tmp/app "$ENV_B"
  run_capture as_child_of "$DAEMON" "$ROOT/bin/notify" claude Stop <<<"$stop_json"
  expect_silent
  assert_not_called ps
}

# The folder reaches the notifier through the hook and through the watcher's
# arguments. Neither may run it, and neither may the command.
test_codex_payload_is_not_run() {
  watch_setup %715
  look_away
  local cwd="/tmp/it's \$(touch ran) \`touch ran\`" json
  cd "$FAKE_LOG" || exit 1
  json=$(jq -nc --arg d "$cwd" '{session_id: "s1", cwd: $d, hook_event_name: "Stop"}')
  daemon_hook Stop "$json"
  assert_stdout_trimmed '{}'
  assert_notifier_arg -message "it's \$(touch ran) \`touch ran\`"

  json=$(jq -nc --arg d "$cwd" --arg s "s'1 \$(touch ran)" --arg c "echo '\$(touch ran)' \`touch ran\`" \
    '{session_id: $s, cwd: $d, tool_name: "Bash", tool_input: {command: $c}}')
  watch_hook "$json"
  wait_for_notifier_calls 2
  assert_no_watchers %715
  assert_notifier_arg -message "echo '\$(touch ran)' \`touch ran\`" 2
  assert_notifier_arg -group "codex-s'1 \$(touch ran)" 2
  if [ -e "$FAKE_LOG/ran" ]; then
    echo "text from hook input was executed" >&2
    exit 1
  fi
}

run_tests \
  test_codex_adapter_values \
  test_codex_stop \
  test_codex_stop_while_looking \
  test_codex_shell_prompt_away \
  test_codex_edit_prompt_away \
  test_codex_detail \
  test_codex_long_command \
  test_codex_look_then_away \
  test_codex_answered_then_away \
  test_codex_prompt_appears_later \
  test_codex_prompt_never_appears \
  test_codex_prompt_on_screen \
  test_codex_unknown_event \
  test_codex_bad_json \
  test_codex_no_session_no_cwd \
  test_codex_no_pane \
  test_codex_daemon_other_pane \
  test_codex_daemon_watcher_other_pane \
  test_codex_daemon_no_pane_in_hook \
  test_codex_daemon_no_match \
  test_codex_parent_is_session \
  test_codex_picks_session_by_folder \
  test_codex_folder_spelling \
  test_codex_session_environment \
  test_codex_locator_tools_fail \
  test_codex_process_text_is_not_run \
  test_other_agents_do_not_locate \
  test_codex_payload_is_not_run
