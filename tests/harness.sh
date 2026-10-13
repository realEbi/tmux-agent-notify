#!/usr/bin/env bash
# Shared fakes and assertions for bin/ tests.
set -u

HARNESS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$HARNESS_DIR/.." && pwd -P)
# Panes a test started watchers for (see harness_track_pane).
HARNESS_PANES=()

harness_use_fakes() {
  FAKE_LOG=$(mktemp -d)
  HIDE_DIR=$(mktemp -d)
  # FAKE_STATE holds answers the fakes re-read on every call (see fake_set).
  FAKE_STATE=$(mktemp -d)
  # Created before TMPDIR is replaced, so it does not nest inside an older one.
  HARNESS_TMPDIR=$(mktemp -d)
  export FAKE_LOG HIDE_DIR FAKE_STATE ROOT
  export TMPDIR="$HARNESS_TMPDIR"
  export PATH="$HIDE_DIR:$HARNESS_DIR/fakes:/bin:/usr/bin"
  unset FAKE_OSA_BUNDLE FAKE_OSA_NAME FAKE_OSA_CONTAINS FAKE_OSA_EXIT
  unset FAKE_ACTIVATE_EXIT FAKE_OSA_DISPLAY_EXIT
  unset FAKE_NOTIFIER_EXIT FAKE_TMUX_DISPLAY FAKE_TMUX_DISPLAY_EXIT
  unset FAKE_TMUX_SELECT_WINDOW_EXIT FAKE_MV_EXIT FAKE_TMUX_CAPTURE_EXIT
  unset TMUX TMUX_PANE __CFBundleIdentifier KEEP_PANE_UNSET
  LAST_STATUS=0
  LAST_STDOUT=
}

# harness_hide NAME
# Put a stub that exits 127 first on PATH, so running NAME fails as if it were
# not installed.
harness_hide() {
  local name="$1"
  printf '%s\n' '#!/bin/sh' 'exit 127' > "$HIDE_DIR/$name"
  chmod +x "$HIDE_DIR/$name"
}

# fake_set NAME VALUE
# Change what a fake answers from its next call on, even for a process that is
# already running. Names: tmux-capture, tmux-capture-exit, tmux-display,
# tmux-pane-pid, osa-bundle, osa-name, and tmux-capture-once, which is the pane
# text for the next capture-pane call only. For the fake ps and lsof: ps-list,
# and for each process id ps-command-PID, ps-env-PID, ps-start-PID and
# lsof-cwd-PID. Written through a temp file and renamed, so a reader never sees
# a half-written value. /bin/mv, not the fake mv, to keep its log clean.
fake_set() {
  local name="$1" value="$2"
  local tmp="$FAKE_STATE/.$name.$$.tmp"
  printf '%s' "$value" > "$tmp"
  /bin/mv -f "$tmp" "$FAKE_STATE/$name"
}

# wait_quiet [SECONDS]
# Give a background worker time to (wrongly) notify before asserting silence.
wait_quiet() {
  sleep "${1:-3}"
}

# wait_until SECONDS COMMAND...
# Run COMMAND every 0.1 seconds until it succeeds. Fails once SECONDS of
# wall-clock time have passed, however long each try took; the clock counts
# whole seconds, so the limit is between SECONDS and one more.
wait_until() {
  local end=$((SECONDS + $1 + 1))
  shift
  while ! "$@"; do
    if [ "$SECONDS" -ge "$end" ]; then
      return 1
    fi
    sleep 0.1
  done
}

# Count the lines in the fake tmux log that are exactly WORD.
tmux_calls() {
  local n=0
  if [ -f "$FAKE_LOG/tmux" ]; then
    n=$(grep -c -x -e "$1" "$FAKE_LOG/tmux")
  fi
  printf '%s\n' "${n:-0}"
}

tmux_called() {
  [ "$(tmux_calls "$1")" -ge "$2" ]
}

wait_for_notifier() {
  wait_until 5 test -f "$FAKE_LOG/terminal-notifier" || {
    echo "timeout waiting for terminal-notifier" >&2
    exit 1
  }
}

# wait_for_polls N
# Wait up to 5 seconds until N polls found you looking. Such a poll ends with
# the pane check, which the fake tmux logs as a display-message line.
wait_for_polls() {
  wait_until 5 tmux_called display-message "$1" || {
    echo "timeout waiting for $1 polls, saw $(tmux_calls display-message)" >&2
    exit 1
  }
}

# Wait up to 5 seconds until a capture-pane call has used up tmux-capture-once.
wait_for_capture_once() {
  wait_until 5 test ! -e "$FAKE_STATE/tmux-capture-once" || {
    echo "timeout waiting for tmux-capture-once to be read" >&2
    exit 1
  }
}

notifier_called() {
  local n=0
  if [ -f "$FAKE_LOG/terminal-notifier" ]; then
    n=$(grep -c -x -e '-title' "$FAKE_LOG/terminal-notifier")
  fi
  [ "$n" -ge "$1" ]
}

wait_for_notifier_calls() {
  wait_until 5 notifier_called "$1" || {
    echo "timeout waiting for $1 terminal-notifier calls" >&2
    exit 1
  }
}

wait_for_captures() {
  wait_until 5 tmux_called capture-pane "$1" || {
    echo "timeout waiting for $1 capture-pane calls, saw $(tmux_calls capture-pane)" >&2
    exit 1
  }
}

run_capture() {
  set +e
  LAST_STDOUT=$("$@" 2>>"$FAKE_LOG/stderr")
  LAST_STATUS=$?
  set -e
}

assert_exit() {
  if [ "$LAST_STATUS" != "$1" ]; then
    echo "assert_exit: expected $1 got $LAST_STATUS" >&2
    echo "stdout: [$LAST_STDOUT]" >&2
    if [ -f "$FAKE_LOG/stderr" ]; then
      echo "stderr:" >&2
      cat "$FAKE_LOG/stderr" >&2
    fi
    exit 1
  fi
}

assert_stdout_trimmed() {
  local got
  got=$(printf '%s' "$LAST_STDOUT" | sed 's/[[:space:]]*$//')
  if [ "$got" != "$1" ]; then
    echo "stdout: expected [$1] got [$got]" >&2
    exit 1
  fi
}

assert_log_contains() {
  local file="$FAKE_LOG/$1"
  if [ ! -f "$file" ] || ! grep -F -q -- "$2" "$file"; then
    echo "log $1 missing [$2]" >&2
    if [ -f "$file" ]; then
      echo "--- $1 ---" >&2
      cat "$file" >&2
    fi
    exit 1
  fi
}

assert_log_lacks() {
  local file="$FAKE_LOG/$1"
  if [ -f "$file" ] && grep -F -q -- "$2" "$file"; then
    echo "log $1 unexpectedly contains [$2]" >&2
    cat "$file" >&2
    exit 1
  fi
}

assert_not_called() {
  local file="$FAKE_LOG/$1"
  if [ -f "$file" ]; then
    echo "$1 was called:" >&2
    cat "$file" >&2
    exit 1
  fi
}

# assert_notifier_calls N
# terminal-notifier was called exactly N times. Each call logs one "-title"
# line. A missing log counts as 0.
assert_notifier_calls() {
  local file="$FAKE_LOG/terminal-notifier" got=0
  if [ -f "$file" ]; then
    got=$(grep -c -x -e '-title' "$file")
  fi
  if [ "$got" != "$1" ]; then
    echo "terminal-notifier: expected $1 calls got $got" >&2
    if [ -f "$file" ]; then
      cat "$file" >&2
    fi
    exit 1
  fi
}

# notifier_arg FLAG [N]
# Print the argument after FLAG in the Nth terminal-notifier call (default: the
# first). The fake logs one argument per line, so it is the line after FLAG.
notifier_arg() {
  if [ -f "$FAKE_LOG/terminal-notifier" ]; then
    awk -v flag="$1" -v want="${2:-1}" '
      found { print; exit }
      $0 == flag && ++n == want { found = 1 }
    ' "$FAKE_LOG/terminal-notifier"
  fi
}

# assert_notifier_arg FLAG VALUE [N]
# The whole argument is compared, so text in another argument cannot match.
assert_notifier_arg() {
  local got
  got=$(notifier_arg "$1" "${3:-1}")
  if [ "$got" != "$2" ]; then
    echo "terminal-notifier $1: expected [$2] got [$got]" >&2
    if [ -f "$FAKE_LOG/terminal-notifier" ]; then
      cat "$FAKE_LOG/terminal-notifier" >&2
    fi
    exit 1
  fi
}

# assert_log_line LOG LINE
# One whole line of the log is exactly LINE.
assert_log_line() {
  local file="$FAKE_LOG/$1"
  if [ ! -f "$file" ] || ! grep -F -x -q -- "$2" "$file"; then
    echo "log $1 has no line [$2]" >&2
    if [ -f "$file" ]; then
      cat "$file" >&2
    fi
    exit 1
  fi
}

# Print the processes whose command line has both "--watch" (or "--watch-turn")
# and PANE as whole arguments. Filtered in bash, so no helper process carries
# the pattern.
harness_watchers() {
  local pane="$1" listing pid cmd
  # /bin/ps, not the fake ps, to see real processes and keep its log clean.
  listing=$(/bin/ps -axo pid=,command=) || {
    echo "harness_watchers: ps failed" >&2
    return 1
  }
  while read -r pid cmd; do
    case " $cmd " in
      *" --watch "* | *" --watch-turn "*) ;;
      *) continue ;;
    esac
    case " $cmd " in
      *" $pane "*) printf '%s %s\n' "$pid" "$cmd" ;;
    esac
  done <<EOF_PS
$listing
EOF_PS
}

watcher_count_is() {
  local found n=0
  found=$(harness_watchers "$1") || return 1
  if [ -n "$found" ]; then
    n=$(printf '%s\n' "$found" | grep -c .)
  fi
  [ "$n" = "$2" ]
}

# Stop every watcher for PANE. A watcher leads its own process group, so the
# sleep it waits on goes with it.
harness_kill_watchers() {
  local pid rest
  while read -r pid rest; do
    if [ -n "$pid" ]; then
      kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null
    fi
  done <<EOF_KILL
$(harness_watchers "$1")
EOF_KILL
}

# harness_track_pane PANE
# Remember a pane the test starts watchers for. run_tests stops any that are
# left when the test ends, so a failing test leaks none.
harness_track_pane() {
  HARNESS_PANES+=("$1")
}

harness_cleanup() {
  local pane
  if [ "${#HARNESS_PANES[@]}" -gt 0 ]; then
    for pane in "${HARNESS_PANES[@]}"; do
      harness_kill_watchers "$pane"
    done
  fi
}

# wait_for_watchers PANE N
# Wait up to 3 seconds until exactly N watchers run for PANE.
wait_for_watchers() {
  wait_until 3 watcher_count_is "$1" "$2" || {
    echo "expected $2 watchers for pane $1, found:" >&2
    harness_watchers "$1" >&2
    exit 1
  }
}

# assert_no_watchers PANE
# No watcher for PANE is left running. Waits up to 3 seconds first, so a
# watcher that is on its way out is not a failure. One that stays is stopped
# before the test fails.
assert_no_watchers() {
  local pane="$1"
  wait_until 3 watcher_count_is "$pane" 0 || {
    echo "watcher still running for pane $pane:" >&2
    harness_watchers "$pane" >&2
    harness_kill_watchers "$pane"
    exit 1
  }
}

# run_tests NAME...
# Run each test in a subshell and exit 1 when any failed. The subshell is the
# condition of an "if", where set -e has no effect, so assertions call exit.
run_tests() {
  local status=0
  local name
  for name in "$@"; do
    if (
      trap harness_cleanup EXIT
      "$name"
    ); then
      echo "PASS $name"
    else
      echo "FAIL $name" >&2
      status=1
    fi
  done
  exit "$status"
}
