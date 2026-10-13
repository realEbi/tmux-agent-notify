#!/usr/bin/env bash
# Self-tests for the harness and the fakes.
set -u
source "$(dirname "$0")/harness.sh"

test_harness_state_dirs() {
  harness_use_fakes
  [ -d "$FAKE_STATE" ] || { echo "FAKE_STATE is not a directory" >&2; exit 1; }
  [ -d "$TMPDIR" ] || { echo "TMPDIR is not a directory" >&2; exit 1; }
  [ "$TMPDIR" != "$FAKE_STATE" ] || { echo "TMPDIR equals FAKE_STATE" >&2; exit 1; }
  [ "$(bash -c 'printf %s "$FAKE_STATE $TMPDIR"')" = "$FAKE_STATE $TMPDIR" ] ||
    { echo "FAKE_STATE or TMPDIR not exported" >&2; exit 1; }
}

test_harness_fake_set_skips_mv_log() {
  harness_use_fakes
  fake_set osa-name Terminal
  assert_not_called mv
  [ "$(ls -A "$FAKE_STATE")" = "osa-name" ] ||
    { echo "unexpected files: $(ls -A "$FAKE_STATE")" >&2; exit 1; }
}

test_harness_capture_env_fallback() {
  harness_use_fakes
  export FAKE_TMUX_CAPTURE='from env'
  run_capture tmux capture-pane -p -t %1
  assert_exit 0
  assert_stdout_trimmed 'from env'
  export FAKE_TMUX_CAPTURE_EXIT=3
  run_capture tmux capture-pane -p -t %1
  assert_exit 3
}

test_harness_capture_changes() {
  harness_use_fakes
  export FAKE_TMUX_CAPTURE='from env'
  fake_set tmux-capture $'line one\nline two'
  run_capture tmux capture-pane -p -t %1
  assert_exit 0
  assert_stdout_trimmed $'line one\nline two'
  fake_set tmux-capture 'changed'
  run_capture tmux capture-pane -p -t %1
  assert_stdout_trimmed 'changed'
}

test_harness_capture_once() {
  harness_use_fakes
  fake_set tmux-capture 'steady'
  fake_set tmux-capture-once 'just once'
  run_capture tmux capture-pane -p -t %1
  assert_stdout_trimmed 'just once'
  wait_for_capture_once
  run_capture tmux capture-pane -p -t %1
  assert_stdout_trimmed 'steady'
  [ "$(ls -A "$FAKE_STATE")" = tmux-capture ] ||
    { echo "unexpected files: $(ls -A "$FAKE_STATE")" >&2; exit 1; }
}

test_harness_capture_exit() {
  harness_use_fakes
  export FAKE_TMUX_CAPTURE_EXIT=3
  fake_set tmux-capture-exit 1
  run_capture tmux capture-pane -p -t %1
  assert_exit 1
  fake_set tmux-capture-exit 0
  run_capture tmux capture-pane -p -t %1
  assert_exit 0
}

test_harness_display_changes() {
  harness_use_fakes
  run_capture tmux display-message -p -t %1 fmt
  assert_stdout_trimmed '1 1 1'
  export FAKE_TMUX_DISPLAY='0 1 1'
  run_capture tmux display-message -p -t %1 fmt
  assert_stdout_trimmed '0 1 1'
  fake_set tmux-display '1 0 1'
  run_capture tmux display-message -p -t %1 fmt
  assert_stdout_trimmed '1 0 1'
}

test_harness_osa_bundle_changes() {
  harness_use_fakes
  local q='tell application "System Events" to get bundle identifier of first application process whose frontmost is true'
  run_capture osascript -e "$q"
  assert_stdout_trimmed 'com.example.Other'
  export FAKE_OSA_BUNDLE=com.apple.Terminal
  run_capture osascript -e "$q"
  assert_stdout_trimmed 'com.apple.Terminal'
  fake_set osa-bundle com.example.Browser
  run_capture osascript -e "$q"
  assert_stdout_trimmed 'com.example.Browser'
}

test_harness_osa_name_changes() {
  harness_use_fakes
  local q='tell application "System Events" to get name of first application process whose frontmost is true'
  run_capture osascript -e "$q"
  assert_stdout_trimmed 'Safari'
  export FAKE_OSA_NAME=Terminal
  run_capture osascript -e "$q"
  assert_stdout_trimmed 'Terminal'
  fake_set osa-name Finder
  run_capture osascript -e "$q"
  assert_stdout_trimmed 'Finder'
}

# A process that is already running sees the new value: the point of fake_set.
test_harness_running_process_sees_change() {
  harness_use_fakes
  fake_set tmux-capture before
  (
    i=0
    while [ "$i" -lt 50 ]; do
      if [ "$(tmux capture-pane -p)" = after ]; then
        : > "$FAKE_LOG/saw-after"
        exit 0
      fi
      sleep 0.1
      i=$((i + 1))
    done
  ) &
  sleep 0.3
  fake_set tmux-capture after
  wait
  [ -f "$FAKE_LOG/saw-after" ] || { echo "running reader never saw the change" >&2; exit 1; }
}

test_harness_notifier_calls() {
  harness_use_fakes
  assert_notifier_calls 0
  terminal-notifier -title One -message 'body' -group g
  assert_notifier_calls 1
  terminal-notifier -title Two -message 'other' -group g
  assert_notifier_calls 2
  wait_for_notifier_calls 2
  if (assert_notifier_calls 1) 2>/dev/null; then
    echo "assert_notifier_calls accepted a wrong count" >&2
    exit 1
  fi
}

test_harness_wait_for_notifier() {
  harness_use_fakes
  (sleep 0.3; terminal-notifier -title Late) &
  wait_for_notifier
  assert_notifier_calls 1
  wait
}

test_harness_notifier_arg() {
  harness_use_fakes
  [ -z "$(notifier_arg -message)" ] || { echo "notifier_arg printed something without a log" >&2; exit 1; }
  terminal-notifier -title One -message 'app' -group g1 -execute "'/x/tmux-agent-notify/bin/focus-pane'"
  terminal-notifier -title Two -message 'other' -group g2
  assert_notifier_arg -title One
  assert_notifier_arg -message app
  assert_notifier_arg -group g2 2
  assert_notifier_arg -message other 2
  # A value that is only part of another argument does not match.
  if (assert_notifier_arg -message agent) 2>/dev/null; then
    echo "assert_notifier_arg matched text from another argument" >&2
    exit 1
  fi
  if (assert_notifier_arg -message app 2) 2>/dev/null; then
    echo "assert_notifier_arg read the wrong call" >&2
    exit 1
  fi
  assert_log_line terminal-notifier other
  if (assert_log_line terminal-notifier agent) 2>/dev/null; then
    echo "assert_log_line matched part of a line" >&2
    exit 1
  fi
}

test_harness_wait_until() {
  harness_use_fakes
  (sleep 0.3; : > "$FAKE_LOG/late") &
  wait_until 3 test -f "$FAKE_LOG/late" || { echo "wait_until missed the file" >&2; exit 1; }
  wait
  # The limit is wall-clock time: slow tries do not stretch it.
  SECONDS=0
  if wait_until 1 sh -c 'sleep 0.5; false'; then
    echo "wait_until succeeded on a command that fails" >&2
    exit 1
  fi
  [ "$SECONDS" -le 3 ] || { echo "wait_until took $SECONDS seconds for a 1 second limit" >&2; exit 1; }
}

test_harness_tmux_calls() {
  harness_use_fakes
  [ "$(tmux_calls capture-pane)" = 0 ] || { echo "expected no calls" >&2; exit 1; }
  tmux capture-pane -p -t %1 >/dev/null
  tmux capture-pane -p -t %1 >/dev/null
  tmux display-message -p -t %1 fmt >/dev/null
  [ "$(tmux_calls capture-pane)" = 2 ] || { echo "expected two capture-pane calls" >&2; exit 1; }
  wait_for_captures 2
  wait_for_polls 1
}

test_harness_no_watchers() {
  harness_use_fakes
  local pane="%h$$"
  assert_no_watchers "$pane"
  # Stands in for "bin/notify --watch <agent> <pane> ...". Exits within the grace period.
  bash -c 'sleep 1; :' fake-notify --watch cursor "$pane" title &
  wait_for_watchers "$pane" 1
  assert_no_watchers "$pane"
  wait
  # One that stays alive is reported within the time limit, and stopped.
  bash -c 'trap "kill %1" TERM; sleep 30 & wait' fake-notify --watch cursor "$pane" title &
  local pid=$!
  local ok=0
  # A different pane id that merely starts with the same text is not matched.
  assert_no_watchers "${pane}9"
  SECONDS=0
  (assert_no_watchers "$pane") 2>/dev/null || ok=1
  [ "$ok" = 1 ] || { kill "$pid" 2>/dev/null; echo "assert_no_watchers missed a live watcher" >&2; exit 1; }
  [ "$SECONDS" -le 5 ] || { echo "assert_no_watchers took $SECONDS seconds" >&2; exit 1; }
  wait "$pid" 2>/dev/null
  [ -z "$(harness_watchers "$pane")" ] || { echo "assert_no_watchers left the watcher running" >&2; exit 1; }
}

test_harness_cleanup_stops_watchers() {
  harness_use_fakes
  local pane="%k$$"
  (
    trap harness_cleanup EXIT
    harness_track_pane "$pane"
    bash -c 'trap "kill %1" TERM; sleep 30 & wait' fake-notify --watch cursor "$pane" title &
    wait_for_watchers "$pane" 1
    exit 1
  ) || true
  assert_no_watchers "$pane"
}

test_harness_fake_ps_and_lsof() {
  harness_use_fakes
  run_capture ps -o command= -p 41
  assert_exit 1
  assert_stdout_trimmed ''
  fake_set ps-command-41 '/bin/codex app-server'
  fake_set ps-env-41 '/bin/codex app-server A=1'
  fake_set ps-list '   41 ??       /bin/codex app-server'
  run_capture ps -o command= -p 41
  assert_exit 0
  assert_stdout_trimmed '/bin/codex app-server'
  run_capture ps eww -o command= -p 41
  assert_stdout_trimmed '/bin/codex app-server A=1'
  run_capture ps -axo pid=,tty=,command=
  assert_stdout_trimmed '   41 ??       /bin/codex app-server'
  assert_log_line ps 'eww -o command= -p 41'

  fake_set lsof-cwd-41 /tmp/a
  fake_set lsof-cwd-43 /tmp/c
  run_capture lsof -a -d cwd -p 41,42,43 -Fpn
  assert_exit 1
  assert_stdout_trimmed $'p41\nfcwd\nn/tmp/a\np43\nfcwd\nn/tmp/c'
  run_capture lsof -a -d cwd -p 43 -Fpn
  assert_exit 0
  assert_log_line lsof '-a -d cwd -p 43 -Fpn'
}

test_harness_watchers_use_real_ps() {
  harness_use_fakes
  harness_watchers %none >/dev/null
  assert_not_called ps
}

run_tests \
  test_harness_state_dirs \
  test_harness_fake_set_skips_mv_log \
  test_harness_capture_env_fallback \
  test_harness_capture_changes \
  test_harness_capture_once \
  test_harness_capture_exit \
  test_harness_display_changes \
  test_harness_osa_bundle_changes \
  test_harness_osa_name_changes \
  test_harness_running_process_sees_change \
  test_harness_notifier_calls \
  test_harness_wait_for_notifier \
  test_harness_notifier_arg \
  test_harness_wait_until \
  test_harness_tmux_calls \
  test_harness_no_watchers \
  test_harness_cleanup_stops_watchers \
  test_harness_fake_ps_and_lsof \
  test_harness_watchers_use_real_ps
