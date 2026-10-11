#!/usr/bin/env bash
set -u
source "$(dirname "$0")/harness.sh"

BIN=$(cd "$ROOT/bin" && pwd -P)
STOP_EXPECTED="$BIN/notify cursor stop"
SHELL_EXPECTED="$BIN/notify cursor beforeShellExecution"
MCP_EXPECTED="$BIN/notify cursor beforeMCPExecution"
# Claude Code's commands have the path in single quotes.
CLAUDE_STOP="'$BIN/notify' claude Stop"
CLAUDE_FAILURE="'$BIN/notify' claude StopFailure"
CLAUDE_NOTIFICATION="'$BIN/notify' claude Notification"

# Codex's too.
CODEX_STOP="'$BIN/notify' codex Stop"
CODEX_PERMISSION="'$BIN/notify' codex PermissionRequest"
# The line the installer prints after Codex's, from the adapter.
CODEX_NOTE=$(. "$ROOT/bin/agents/codex.sh" && printf '  %s' "$AGENT_INSTALL_NOTE")

fresh_home() {
  harness_use_fakes
  export HOME
  HOME=$(mktemp -d)
}

# run_install [AGENT...]
# Cursor only when no agent is named. A test that needs the installer to run
# with no arguments calls it through run_capture.
run_install() {
  if [ $# -eq 0 ]; then
    set -- cursor
  fi
  run_capture "$ROOT/bin/install" "$@"
}

# assert_json FILE EXPECTED
# FILE parses to the same value as the JSON text EXPECTED. Exits itself:
# run_tests calls each test inside an "if", where set -e has no effect.
assert_json() {
  python3 - "$1" "$2" <<'PY' || exit 1
import json, sys
with open(sys.argv[1]) as handle:
    data = json.load(handle)
expected = json.loads(sys.argv[2])
if data != expected:
    print(f"assert_json: expected {expected!r} got {data!r}", file=sys.stderr)
    sys.exit(1)
PY
}

# The hooks.json a first install writes.
cursor_created() {
  jq -n --arg stop "$STOP_EXPECTED" --arg shell "$SHELL_EXPECTED" --arg mcp "$MCP_EXPECTED" '{
    version: 1,
    hooks: {
      stop: [{command: $stop}],
      beforeShellExecution: [{command: $shell}],
      beforeMCPExecution: [{command: $mcp}]
    }
  }'
}

# The three groups a first install adds to settings.json, as {Event: group}.
claude_groups() {
  jq -n --arg stop "$CLAUDE_STOP" --arg failure "$CLAUDE_FAILURE" --arg notification "$CLAUDE_NOTIFICATION" '{
    Stop: {hooks: [{type: "command", command: $stop}]},
    StopFailure: {hooks: [{type: "command", command: $failure}]},
    Notification: {matcher: "permission_prompt", hooks: [{type: "command", command: $notification}]}
  }'
}

# The settings.json a first install writes.
claude_created() {
  claude_groups | jq '{hooks: map_values([.])}'
}

# with_claude_groups JSON
# JSON with our three groups appended to its events.
with_claude_groups() {
  local groups
  groups=$(claude_groups)
  printf '%s' "$1" | jq --argjson ours "$groups" '
    reduce ($ours | to_entries[]) as $e (.; .hooks[$e.key] += [$e.value])
  '
}

# The two groups a first install adds to Codex's hooks.json, as {Event: group}.
codex_groups() {
  jq -n --arg stop "$CODEX_STOP" --arg permission "$CODEX_PERMISSION" '{
    Stop: {hooks: [{type: "command", command: $stop}]},
    PermissionRequest: {hooks: [{type: "command", command: $permission}]}
  }'
}

# The hooks.json a first install writes for Codex.
codex_created() {
  codex_groups | jq '{hooks: map_values([.])}'
}

# with_codex_groups JSON
# JSON with our two groups appended to its events.
with_codex_groups() {
  local groups
  groups=$(codex_groups)
  printf '%s' "$1" | jq --argjson ours "$groups" '
    reduce ($ours | to_entries[]) as $e (.; .hooks[$e.key] += [$e.value])
  '
}

codex_path() {
  printf '%s/.codex/hooks.json' "$HOME"
}

assert_created() {
  local expected
  expected=$(cursor_created)
  assert_json "$(hooks_path)" "$expected"
}

hooks_path() {
  printf '%s/.cursor/hooks.json' "$HOME"
}

settings_path() {
  printf '%s/.claude/settings.json' "$HOME"
}

assert_missing() {
  if [ -e "$1" ]; then
    echo "$1 should not exist" >&2
    exit 1
  fi
}

assert_bytes_unchanged() {
  local path="$1" before="$2"
  local after
  after=$(cat "$path")
  if [ "$after" != "$before" ]; then
    echo "assert_bytes_unchanged: file changed" >&2
    echo "before: [$before]" >&2
    echo "after: [$after]" >&2
    exit 1
  fi
}

test_install_creates() {
  fresh_home
  run_install
  assert_exit 0
  assert_created
}

test_install_empty_object() {
  fresh_home
  mkdir -p "$HOME/.cursor"
  printf '%s\n' '{}' > "$(hooks_path)"
  run_install
  assert_exit 0
  assert_created
}

test_install_appends() {
  fresh_home
  mkdir -p "$HOME/.cursor"
  printf '%s\n' '{"version":1,"hooks":{"stop":[{"command":"/bin/other"}]}}' > "$(hooks_path)"
  run_install
  assert_exit 0
  python3 - "$(hooks_path)" "$STOP_EXPECTED" "$SHELL_EXPECTED" "$MCP_EXPECTED" <<'PY' || exit 1
import json, sys
path, ours = sys.argv[1], sys.argv[2]
with open(path) as handle:
    data = json.load(handle)
stop = data["hooks"]["stop"]
if len(stop) != 2:
    print(f"expected 2 stop entries, got {len(stop)}", file=sys.stderr)
    sys.exit(1)
if stop[0] != {"command": "/bin/other"}:
    print(f"first entry wrong: {stop[0]!r}", file=sys.stderr)
    sys.exit(1)
if stop[1] != {"command": ours}:
    print(f"second entry wrong: {stop[1]!r}", file=sys.stderr)
    sys.exit(1)
for name, approval in (("beforeShellExecution", sys.argv[3]), ("beforeMCPExecution", sys.argv[4])):
    arr = data["hooks"].get(name, [])
    if len(arr) != 1 or arr[0].get("command") != approval:
        print(f"{name} wrong: {arr!r}", file=sys.stderr)
        sys.exit(1)
PY
}

test_install_keeps_non_object() {
  fresh_home
  mkdir -p "$HOME/.cursor"
  printf '%s\n' '{"hooks":{"stop":[null,"x"]}}' > "$(hooks_path)"
  run_install
  assert_exit 0
  python3 - "$(hooks_path)" "$STOP_EXPECTED" <<'PY' || exit 1
import json, sys
path, ours = sys.argv[1], sys.argv[2]
with open(path) as handle:
    data = json.load(handle)
stop = data["hooks"]["stop"]
if len(stop) != 3:
    print(f"expected 3 stop entries, got {len(stop)}", file=sys.stderr)
    sys.exit(1)
if stop[0] is not None or stop[1] != "x":
    print(f"prefix wrong: {stop[:2]!r}", file=sys.stderr)
    sys.exit(1)
if stop[2] != {"command": ours}:
    print(f"last entry wrong: {stop[2]!r}", file=sys.stderr)
    sys.exit(1)
PY
}

test_install_idempotent() {
  fresh_home
  run_install
  assert_exit 0
  run_install
  assert_exit 0
  python3 - "$(hooks_path)" <<'PY' || exit 1
import json, sys
with open(sys.argv[1]) as handle:
    data = json.load(handle)
if len(data["hooks"]["stop"]) != 1:
    print(f"expected stop length 1, got {len(data['hooks']['stop'])}", file=sys.stderr)
    sys.exit(1)
for name in ("beforeShellExecution", "beforeMCPExecution"):
    if len(data["hooks"][name]) != 1:
        print(f"expected {name} length 1", file=sys.stderr)
        sys.exit(1)
PY
}

test_install_registers_approval_idempotent() {
  fresh_home
  run_install
  assert_exit 0
  run_install
  assert_exit 0
  python3 - "$(hooks_path)" <<'PY' || exit 1
import json, sys
with open(sys.argv[1]) as handle:
    data = json.load(handle)
for name in ("beforeShellExecution", "beforeMCPExecution", "stop"):
    if len(data["hooks"][name]) != 1:
        print(f"duplicate {name}", file=sys.stderr)
        sys.exit(1)
PY
}

test_install_invalid_json() {
  fresh_home
  mkdir -p "$HOME/.cursor"
  local path
  path=$(hooks_path)
  printf '%s' 'not-json' > "$path"
  local before
  before=$(cat "$path")
  run_install
  assert_exit 1
  assert_bytes_unchanged "$path" "$before"
}

test_install_hooks_json_is_directory() {
  fresh_home
  mkdir -p "$HOME/.cursor/hooks.json"
  run_install
  assert_exit 1
  if [ ! -d "$HOME/.cursor/hooks.json" ]; then
    echo "hooks.json directory missing" >&2
    exit 1
  fi
}

test_install_cursor_is_file() {
  fresh_home
  printf '%s' 'keep' > "$HOME/.cursor"
  run_install
  assert_exit 1
  if [ -f "$(hooks_path)" ]; then
    echo "hooks.json should not exist" >&2
    exit 1
  fi
  if [ "$(cat "$HOME/.cursor")" != 'keep' ]; then
    echo ".cursor file changed" >&2
    exit 1
  fi
}

test_install_mv_fails() {
  fresh_home
  mkdir -p "$HOME/.cursor"
  printf '%s\n' '{"version":1,"hooks":{"stop":[{"command":"/bin/other"}]}}' > "$(hooks_path)"
  export FAKE_MV_EXIT=1
  run_install
  assert_exit 1
  python3 - "$(hooks_path)" <<'PY' || exit 1
import json, sys
with open(sys.argv[1]) as handle:
    data = json.load(handle)
cmd = data["hooks"]["stop"][0]["command"]
if cmd != "/bin/other":
    print(f"expected /bin/other got {cmd!r}", file=sys.stderr)
    sys.exit(1)
PY
}

test_install_via_symlink() {
  fresh_home
  ln -s "$ROOT/bin/install" "$HOME/install-link"
  set +e
  LAST_STDOUT=$(cd / && HOME="$HOME" PATH="$PATH" "$HOME/install-link" cursor 2>>"$FAKE_LOG/stderr")
  LAST_STATUS=$?
  set -e
  assert_exit 0
  assert_created
  python3 - "$(hooks_path)" "$HOME" <<'PY' || exit 1
import json, sys
path, home = sys.argv[1], sys.argv[2]
with open(path) as handle:
    data = json.load(handle)
cmd = data["hooks"]["stop"][0]["command"]
if cmd.startswith(home):
    print(f"command must not start with HOME: {cmd!r}", file=sys.stderr)
    sys.exit(1)
PY
}

test_install_bad_version() {
  fresh_home
  mkdir -p "$HOME/.cursor"
  local path
  path=$(hooks_path)
  printf '%s\n' '{"version":2,"hooks":{"stop":[]}}' > "$path"
  local before
  before=$(cat "$path")
  run_install
  assert_exit 1
  assert_bytes_unchanged "$path" "$before"
}

test_install_root_array() {
  fresh_home
  mkdir -p "$HOME/.cursor"
  local path
  path=$(hooks_path)
  printf '%s\n' '[]' > "$path"
  local before
  before=$(cat "$path")
  run_install
  assert_exit 1
  assert_bytes_unchanged "$path" "$before"
}

test_install_hooks_not_object() {
  fresh_home
  mkdir -p "$HOME/.cursor"
  local path
  path=$(hooks_path)
  printf '%s\n' '{"hooks":[]}' > "$path"
  local before
  before=$(cat "$path")
  run_install
  assert_exit 1
  assert_bytes_unchanged "$path" "$before"
}

test_install_stop_not_array() {
  fresh_home
  mkdir -p "$HOME/.cursor"
  local path
  path=$(hooks_path)
  printf '%s\n' '{"hooks":{"stop":{}}}' > "$path"
  local before
  before=$(cat "$path")
  run_install
  assert_exit 1
  assert_bytes_unchanged "$path" "$before"
}


test_install_bool_version() {
  fresh_home
  mkdir -p "$HOME/.cursor"
  local path
  path=$(hooks_path)
  printf '%s\n' '{"version":true,"hooks":{"stop":[]}}' > "$path"
  local before
  before=$(cat "$path")
  run_install
  assert_exit 1
  assert_bytes_unchanged "$path" "$before"
}

test_install_no_jq() {
  fresh_home
  harness_hide jq
  run_install
  assert_exit 1
  assert_log_contains stderr 'install: jq not found'
  if [ -e "$(hooks_path)" ]; then
    echo "hooks.json should not exist" >&2
    exit 1
  fi
}

test_install_cleans_tmp_on_mv_failure() {
  fresh_home
  mkdir -p "$HOME/.cursor"
  printf '%s\n' '{"version":1,"hooks":{"stop":[{"command":"/bin/other"}]}}' > "$(hooks_path)"
  export FAKE_MV_EXIT=1
  run_install
  assert_exit 1
  local leftover
  leftover=$(find "$HOME/.cursor" -maxdepth 1 -name 'hooks.json.*' 2>/dev/null || true)
  if [ -n "$leftover" ]; then
    echo "temp hooks.json.* left behind: $leftover" >&2
    exit 1
  fi
}

test_install_removes_old_entries() {
  fresh_home
  mkdir -p "$HOME/.cursor"
  local fixture expected
  fixture=$(jq -n --arg bin "$BIN" '{
    version: 1,
    hooks: {
      stop: [{command: ($bin + "/notify-on-stop")}, {command: "/bin/other"}],
      beforeShellExecution: [{command: "/elsewhere/tmux-cursor-notify/bin/notify-on-approval"}],
      beforeMCPExecution: [{command: ($bin + "/notify-on-approval")}],
      afterFileEdit: [
        {command: "/elsewhere/tmux-cursor-notify/bin/notify cursor stop"},
        {command: "/bin/keep"},
        {command: "/elsewhere/tmux-agent-notify/bin/notify cursor beforeShellExecution"},
        {command: "/elsewhere/tmux-cursor-notify/bin/notify-on-stop"}
      ]
    }
  }')
  printf '%s\n' "$fixture" > "$(hooks_path)"
  run_install
  assert_exit 0
  expected=$(jq -n --arg stop "$STOP_EXPECTED" --arg shell "$SHELL_EXPECTED" --arg mcp "$MCP_EXPECTED" '{
    version: 1,
    hooks: {
      stop: [{command: "/bin/other"}, {command: $stop}],
      beforeShellExecution: [{command: $shell}],
      beforeMCPExecution: [{command: $mcp}],
      afterFileEdit: [{command: "/bin/keep"}]
    }
  }')
  assert_json "$(hooks_path)" "$expected"
}

# After old entries were replaced, a second run changes nothing.
test_install_removes_old_idempotent() {
  fresh_home
  mkdir -p "$HOME/.cursor"
  local fixture before
  fixture=$(jq -n --arg bin "$BIN" '{
    version: 1,
    hooks: {
      stop: [{command: ($bin + "/notify-on-stop")}, {command: "/bin/other"}],
      beforeShellExecution: [{command: "/elsewhere/tmux-cursor-notify/bin/notify cursor beforeShellExecution"}]
    }
  }')
  printf '%s\n' "$fixture" > "$(hooks_path)"
  run_install
  assert_exit 0
  before=$(cat "$(hooks_path)")
  if grep -q 'notify-on-' "$(hooks_path)"; then
    echo "old entry still there: $before" >&2
    exit 1
  fi
  run_install
  assert_exit 0
  assert_bytes_unchanged "$(hooks_path)" "$before"
}

test_install_keeps_unrelated() {
  fresh_home
  mkdir -p "$HOME/.cursor"
  # None of these is ours: another tool, a name that only contains ours, our
  # name in the wrong part of the path, or extra or missing arguments.
  local fixture expected
  fixture=$(jq -n '{
    version: 1,
    hooks: {
      stop: [
        {command: "/usr/local/bin/notify cursor stop"},
        {command: "/x/other-tool/bin/notify-on-stop"},
        {command: "/x/tmux-cursor-notify-fork/bin/notify-on-stop"},
        {command: "/x/tmux-cursor-notify/other/bin/notify cursor stop"},
        {command: "/x/tmux-cursor-notify/other/bin/notify-on-stop"},
        {command: "/x/my-tmux-agent-notify/bin/notify cursor stop"},
        {command: "/x/tmux-cursor-notify/bin/notify"},
        {command: "/x/tmux-agent-notify/bin/notify cursor"},
        {command: "/x/tmux-agent-notify/bin/notify cursor stop --flag"},
        {command: "/x/tmux-cursor-notify/bin/notify-on-stop --flag"},
        {command: "echo /x/tmux-cursor-notify/bin/notify-on-stop"},
        {command: "/x/tmux-cursor-notify/bin/notify-on-stopped"},
        {command: "/x/tmux-agent-notify/bin/notify-on-stop"},
        {command: "/x/tmux-cursor-notify/bin/focus-pane"}
      ],
      afterFileEdit: [{command: "/x/other-tool/bin/notify-on-approval"}],
      odd: "not an array"
    },
    other: {keep: true}
  }')
  printf '%s\n' "$fixture" > "$(hooks_path)"
  run_install
  assert_exit 0
  expected=$(printf '%s' "$fixture" | jq --arg stop "$STOP_EXPECTED" --arg shell "$SHELL_EXPECTED" --arg mcp "$MCP_EXPECTED" '
    .hooks.stop += [{command: $stop}]
    | .hooks.beforeShellExecution = [{command: $shell}]
    | .hooks.beforeMCPExecution = [{command: $mcp}]
  ')
  assert_json "$(hooks_path)" "$expected"
}

# An entry that already points at this checkout stays where it is.
test_install_keeps_current_entry() {
  fresh_home
  mkdir -p "$HOME/.cursor"
  local fixture expected
  fixture=$(jq -n --arg stop "$STOP_EXPECTED" '{
    version: 1,
    hooks: {stop: [{command: "/bin/first"}, {command: $stop, timeout: 5}, {command: "/bin/last"}]}
  }')
  printf '%s\n' "$fixture" > "$(hooks_path)"
  run_install
  assert_exit 0
  expected=$(printf '%s' "$fixture" | jq --arg shell "$SHELL_EXPECTED" --arg mcp "$MCP_EXPECTED" '
    .hooks.beforeShellExecution = [{command: $shell}]
    | .hooks.beforeMCPExecution = [{command: $mcp}]
  ')
  assert_json "$(hooks_path)" "$expected"
}

test_install_claude_creates() {
  fresh_home
  run_install claude
  assert_exit 0
  local expected
  expected=$(claude_created)
  assert_json "$(settings_path)" "$expected"
  assert_missing "$HOME/.cursor"
}

test_install_claude_empty_file() {
  fresh_home
  mkdir -p "$HOME/.claude"
  : > "$(settings_path)"
  run_install claude
  assert_exit 0
  local expected
  expected=$(claude_created)
  assert_json "$(settings_path)" "$expected"
}

# A file of only spaces and newlines counts as empty, for both shapes.
test_install_blank_file() {
  local expected
  fresh_home
  mkdir -p "$HOME/.claude" "$HOME/.cursor"
  printf ' \n\t\n\n' > "$(settings_path)"
  printf '\n  \n' > "$(hooks_path)"
  run_install claude cursor
  assert_exit 0
  expected=$(claude_created)
  assert_json "$(settings_path)" "$expected"
  assert_created
}

# file_mode FILE
# The permission bits in octal, such as 644.
file_mode() {
  stat -f %Lp "$1"
}

# The file keeps the permission bits it had. A new file is private.
test_install_keeps_mode() {
  local mode
  for mode in 644 600 640; do
    fresh_home
    mkdir -p "$HOME/.claude" "$HOME/.cursor"
    printf '%s\n' '{"env":{"A":"1"}}' > "$(settings_path)"
    printf '%s\n' '{}' > "$(hooks_path)"
    chmod "$mode" "$(settings_path)" "$(hooks_path)"
    run_install claude cursor
    assert_exit 0
    assert_created
    [ "$(file_mode "$(settings_path)")" = "$mode" ] ||
      { echo "settings.json: mode $mode became $(file_mode "$(settings_path)")" >&2; exit 1; }
    [ "$(file_mode "$(hooks_path)")" = "$mode" ] ||
      { echo "hooks.json: mode $mode became $(file_mode "$(hooks_path)")" >&2; exit 1; }
  done

  fresh_home
  run_install claude
  assert_exit 0
  [ "$(file_mode "$(settings_path)")" = 600 ] ||
    { echo "new settings.json has mode $(file_mode "$(settings_path)")" >&2; exit 1; }

  # Behind a symlink, the mode is that of the file, not of the link.
  fresh_home
  mkdir -p "$HOME/.claude"
  printf '%s\n' '{}' > "$HOME/real.json"
  chmod 640 "$HOME/real.json"
  ln -s "$HOME/real.json" "$(settings_path)"
  run_install claude
  assert_exit 0
  [ "$(file_mode "$(settings_path)")" = 640 ] ||
    { echo "symlinked settings.json got mode $(file_mode "$(settings_path)")" >&2; exit 1; }
}

# An agent named more than once is installed once, in first-named order.
test_install_repeated_agent() {
  fresh_home
  run_install claude claude cursor claude
  assert_exit 0
  assert_stdout_trimmed "claude: $(settings_path)
cursor: $(hooks_path)"
  [ "$(grep -c -F -x "$(settings_path)" "$FAKE_LOG/mv")" = 1 ] ||
    { echo "settings.json was written more than once" >&2; cat "$FAKE_LOG/mv" >&2; exit 1; }
  local expected
  expected=$(claude_created)
  assert_json "$(settings_path)" "$expected"
  assert_created
}

test_install_claude_merges() {
  fresh_home
  mkdir -p "$HOME/.claude"
  local fixture expected
  fixture='{
    "permissions": {"allow": ["Bash(ls:*)"]},
    "env": {"A": "1"},
    "version": 7,
    "hooks": {
      "Stop": [{"hooks": [{"type": "command", "command": "/bin/theirs"}]}],
      "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/bin/guard"}]}]
    }
  }'
  printf '%s\n' "$fixture" > "$(settings_path)"
  run_install claude
  assert_exit 0
  expected=$(with_claude_groups "$fixture")
  assert_json "$(settings_path)" "$expected"
}

test_install_claude_idempotent() {
  fresh_home
  mkdir -p "$HOME/.claude"
  local fixture='{"env":{"A":"1"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/theirs"}]}]}}'
  local expected before
  printf '%s\n' "$fixture" > "$(settings_path)"
  run_install claude
  assert_exit 0
  expected=$(with_claude_groups "$fixture")
  assert_json "$(settings_path)" "$expected"
  before=$(cat "$(settings_path)")
  run_install claude
  assert_exit 0
  assert_bytes_unchanged "$(settings_path)" "$before"
}

# Our command inside a group someone else wrote counts as installed.
test_install_claude_finds_command_in_any_group() {
  fresh_home
  mkdir -p "$HOME/.claude"
  local fixture groups expected
  fixture=$(jq -n --arg stop "$CLAUDE_STOP" '{
    hooks: {Stop: [
      {hooks: [{type: "command", command: "/bin/first"}]},
      {matcher: "", hooks: [{type: "command", command: "/bin/theirs"}, {type: "command", command: $stop, timeout: 5}]}
    ]}
  }')
  printf '%s\n' "$fixture" > "$(settings_path)"
  run_install claude
  assert_exit 0
  groups=$(claude_groups)
  expected=$(printf '%s' "$fixture" | jq --argjson ours "$groups" '
    .hooks.StopFailure = [$ours.StopFailure]
    | .hooks.Notification = [$ours.Notification]
  ')
  assert_json "$(settings_path)" "$expected"
}

test_install_claude_removes_stale() {
  fresh_home
  mkdir -p "$HOME/.claude"
  local q="'" fixture groups expected before
  fixture=$(jq -n --arg q "$q" '{
    hooks: {
      Stop: [
        {hooks: [{type: "command", command: ($q + "/elsewhere/tmux-agent-notify/bin/notify" + $q + " claude Stop")}]},
        {matcher: "x", hooks: [
          {type: "command", command: ($q + "/old/tmux-cursor-notify/bin/notify" + $q + " claude Stop")},
          {type: "command", command: "/bin/theirs"}
        ]},
        {hooks: []}
      ],
      PreToolUse: [
        {hooks: [{type: "command", command: "/elsewhere/tmux-cursor-notify/bin/notify-on-stop"}]},
        {matcher: "Bash", hooks: [{type: "command", command: "/bin/guard"}]}
      ]
    }
  }')
  printf '%s\n' "$fixture" > "$(settings_path)"
  run_install claude
  assert_exit 0
  groups=$(claude_groups)
  # The empty group was not ours, so it stays.
  expected=$(jq -n --argjson ours "$groups" '{
    hooks: {
      Stop: [
        {matcher: "x", hooks: [{type: "command", command: "/bin/theirs"}]},
        {hooks: []},
        $ours.Stop
      ],
      PreToolUse: [{matcher: "Bash", hooks: [{type: "command", command: "/bin/guard"}]}],
      StopFailure: [$ours.StopFailure],
      Notification: [$ours.Notification]
    }
  }')
  assert_json "$(settings_path)" "$expected"
  before=$(cat "$(settings_path)")
  run_install claude
  assert_exit 0
  assert_bytes_unchanged "$(settings_path)" "$before"
}

test_install_claude_keeps_unrelated() {
  fresh_home
  mkdir -p "$HOME/.claude"
  # The last one is this checkout, written without quotes: not another install.
  local q="'" fixture expected
  fixture=$(jq -n --arg q "$q" --arg bin "$BIN" '{
    hooks: {
      SessionEnd: [{hooks: [{type: "command", command: ($bin + "/notify claude SessionEnd")}]}],
      Stop: [
        {hooks: [{type: "command", command: ($q + "/usr/local/bin/notify" + $q + " claude Stop")}]},
        {hooks: [{type: "command", command: ($q + "/x/tmux-agent-notify-fork/bin/notify" + $q + " claude Stop")}]},
        {hooks: [{type: "command", command: "/x/tmux-agent-notify/other/bin/notify claude Stop"}]},
        {hooks: [{type: "command", command: "/x/other-tool/bin/notify-on-stop"}]}
      ]
    }
  }')
  printf '%s\n' "$fixture" > "$(settings_path)"
  run_install claude
  assert_exit 0
  expected=$(with_claude_groups "$fixture")
  assert_json "$(settings_path)" "$expected"
}

test_install_claude_keeps_non_object() {
  fresh_home
  mkdir -p "$HOME/.claude"
  local fixture expected
  fixture='{"hooks":{"Stop":[null,"x",5,[],{"hooks":"s"},{"hooks":[null,"y",{"command":7}]},{"matcher":"m"}],"Other":"text"}}'
  printf '%s\n' "$fixture" > "$(settings_path)"
  run_install claude
  assert_exit 0
  expected=$(with_claude_groups "$fixture")
  assert_json "$(settings_path)" "$expected"
}

test_install_claude_invalid() {
  local content path before
  for content in 'not-json' '[]' 'null' '{"hooks":[]}' '{"hooks":{"Stop":{}}}' '{} {}'; do
    fresh_home
    mkdir -p "$HOME/.claude"
    path=$(settings_path)
    printf '%s\n' "$content" > "$path"
    before=$(cat "$path")
    run_install claude
    if [ "$LAST_STATUS" = 0 ]; then
      echo "install succeeded for [$content]" >&2
      exit 1
    fi
    assert_log_contains stderr 'install: '
    assert_bytes_unchanged "$path" "$before"
  done
}

test_install_claude_path_with_quote() {
  fresh_home
  # A copy of bin/ in a directory whose name has a single quote.
  local checkout="$HOME/it's here/tmux-agent-notify" copy command before
  mkdir -p "$checkout"
  cp -R "$ROOT/bin" "$checkout/bin"
  copy=$(cd "$checkout/bin" && pwd -P)
  run_capture "$copy/install" claude
  assert_exit 0
  # The command was written by our own copy of the installer into a temp HOME,
  # so letting the shell split it is safe.
  command=$(jq -r '.hooks.Notification[0].hooks[0].command' "$(settings_path)")
  eval "set -- $command"
  if [ $# -ne 3 ] || [ "$1" != "$copy/notify" ] || [ "$2 $3" != 'claude Notification' ]; then
    echo "command does not split back: [$command] gave [$*]" >&2
    exit 1
  fi
  # A second run sees its own entries and changes nothing.
  before=$(cat "$(settings_path)")
  run_capture "$copy/install" claude
  assert_exit 0
  assert_bytes_unchanged "$(settings_path)" "$before"
}

test_install_detects_agents() {
  local expected
  # Only ~/.claude: Claude Code is installed and ~/.cursor is not created.
  fresh_home
  mkdir -p "$HOME/.claude"
  run_capture "$ROOT/bin/install"
  assert_exit 0
  expected=$(claude_created)
  assert_json "$(settings_path)" "$expected"
  assert_missing "$HOME/.cursor"

  # Both present: both installed.
  fresh_home
  mkdir -p "$HOME/.claude" "$HOME/.cursor"
  run_capture "$ROOT/bin/install"
  assert_exit 0
  assert_json "$(settings_path)" "$expected"
  assert_created

  # Neither: an error, and nothing is created.
  fresh_home
  run_capture "$ROOT/bin/install"
  assert_exit 1
  assert_log_contains stderr 'install: '
  assert_missing "$HOME/.claude"
  assert_missing "$HOME/.cursor"
}

test_install_unknown_agent() {
  fresh_home
  run_install cursor nosuch
  assert_exit 1
  assert_log_contains stderr 'install: unknown agent: nosuch'
  assert_missing "$HOME/.cursor"
  if [ -n "$LAST_STDOUT" ]; then
    echo "unexpected stdout: [$LAST_STDOUT]" >&2
    exit 1
  fi
}

test_install_invalid_agent_name() {
  local name
  # A name is only lowercase letters, so none of these reaches a file path.
  for name in '../x' 'Cursor' '' 'cursor.sh' 'agents/cursor' 'cursor claude'; do
    fresh_home
    run_install claude "$name" cursor
    assert_exit 1
    assert_log_contains stderr 'install: unknown agent: '
    assert_missing "$HOME/.cursor"
    assert_missing "$HOME/.claude"
  done
}

test_install_one_fails_other_continues() {
  fresh_home
  mkdir -p "$HOME/.cursor" "$HOME/.claude"
  local path before expected
  path=$(hooks_path)
  printf '%s' 'not-json' > "$path"
  before=$(cat "$path")
  printf '%s\n' '{"env":{"A":"1"}}' > "$(settings_path)"
  run_install cursor claude
  assert_exit 1
  assert_log_contains stderr 'install: '
  assert_bytes_unchanged "$path" "$before"
  expected=$(with_claude_groups '{"env":{"A":"1"}}')
  assert_json "$(settings_path)" "$expected"
  # Only the agent that was installed is printed.
  assert_stdout_trimmed "claude: $(settings_path)"
}

test_install_prints_agents() {
  fresh_home
  run_install cursor claude
  assert_exit 0
  assert_stdout_trimmed "cursor: $(hooks_path)
claude: $(settings_path)"
}

test_install_claude_mv_fails() {
  fresh_home
  mkdir -p "$HOME/.claude"
  local path before leftover
  path=$(settings_path)
  printf '%s\n' '{"env":{"A":"1"}}' > "$path"
  before=$(cat "$path")
  export FAKE_MV_EXIT=1
  run_install claude
  assert_exit 1
  assert_bytes_unchanged "$path" "$before"
  leftover=$(find "$HOME/.claude" -maxdepth 1 -name 'settings.json.*' 2>/dev/null || true)
  if [ -n "$leftover" ]; then
    echo "temp settings.json.* left behind: $leftover" >&2
    exit 1
  fi
}

test_install_codex_creates() {
  fresh_home
  run_install codex
  assert_exit 0
  local expected
  expected=$(codex_created)
  assert_json "$(codex_path)" "$expected"
  # No matcher, and no version key as in Cursor's file.
  [ "$(jq -c '[.. | objects | keys[]] | unique' "$(codex_path)")" = '["PermissionRequest","Stop","command","hooks","type"]' ] ||
    { echo "unexpected keys in $(codex_path)" >&2; cat "$(codex_path)" >&2; exit 1; }
  assert_missing "$HOME/.cursor"
  assert_missing "$HOME/.claude"
  # The file's line, then what is left for you to do.
  assert_stdout_trimmed "codex: $(codex_path)
$CODEX_NOTE"
  case $CODEX_NOTE in
    *trust*/hooks*) ;;
    *) echo "the note does not say how to trust the hooks: [$CODEX_NOTE]" >&2; exit 1 ;;
  esac
}

test_install_codex_empty_file() {
  fresh_home
  mkdir -p "$HOME/.codex"
  : > "$(codex_path)"
  run_install codex
  assert_exit 0
  local expected
  expected=$(codex_created)
  assert_json "$(codex_path)" "$expected"
}

# Other hooks and the description are kept, and a second run changes nothing.
test_install_codex_merges_idempotent() {
  fresh_home
  mkdir -p "$HOME/.codex"
  local fixture expected before
  fixture='{
    "description": "my hooks",
    "hooks": {
      "Stop": [{"hooks": [{"type": "command", "command": "/bin/theirs"}]}],
      "PermissionRequest": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/bin/guard"}]}],
      "SessionStart": [{"hooks": [{"type": "command", "command": "/bin/hello"}]}]
    }
  }'
  printf '%s\n' "$fixture" > "$(codex_path)"
  run_install codex
  assert_exit 0
  expected=$(with_codex_groups "$fixture")
  assert_json "$(codex_path)" "$expected"
  before=$(cat "$(codex_path)")
  run_install codex
  assert_exit 0
  assert_bytes_unchanged "$(codex_path)" "$before"
  # The note is printed again: the installer cannot see whether you trusted them.
  assert_stdout_trimmed "codex: $(codex_path)
$CODEX_NOTE"
}

# Entries written from another checkout are replaced; a group keeps its other hooks.
test_install_codex_removes_stale() {
  fresh_home
  mkdir -p "$HOME/.codex"
  local q="'" fixture expected
  fixture=$(jq -n --arg old "${q}/old/tmux-agent-notify/bin/notify${q} codex Stop" \
    --arg oldp "${q}/old/tmux-agent-notify/bin/notify${q} codex PermissionRequest" '{
    hooks: {
      Stop: [{hooks: [{type: "command", command: $old}, {type: "command", command: "/bin/theirs"}]}],
      PermissionRequest: [{hooks: [{type: "command", command: $oldp}]}]
    }
  }')
  printf '%s\n' "$fixture" > "$(codex_path)"
  run_install codex
  assert_exit 0
  expected=$(with_codex_groups '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/theirs"}]}],"PermissionRequest":[]}}')
  assert_json "$(codex_path)" "$expected"
}

test_install_codex_invalid() {
  local content before
  for content in 'not-json' '[]' '{"hooks":[]}' '{"hooks":{"Stop":{}}}'; do
    fresh_home
    mkdir -p "$HOME/.codex"
    printf '%s' "$content" > "$(codex_path)"
    before=$(cat "$(codex_path)")
    run_install codex
    assert_exit 1
    assert_log_contains stderr 'install: cannot update'
    assert_bytes_unchanged "$(codex_path)" "$before"
    # Nothing was installed, so there is nothing to trust.
    assert_stdout_trimmed ''
  done
}

test_install_detects_codex() {
  local expected
  # Only ~/.codex: Codex is installed and the other directories are not created.
  fresh_home
  mkdir -p "$HOME/.codex"
  run_capture "$ROOT/bin/install"
  assert_exit 0
  expected=$(codex_created)
  assert_json "$(codex_path)" "$expected"
  assert_missing "$HOME/.cursor"
  assert_missing "$HOME/.claude"
  assert_stdout_trimmed "codex: $(codex_path)
$CODEX_NOTE"

  # All three present: all installed, and the note follows Codex's line only.
  fresh_home
  mkdir -p "$HOME/.claude" "$HOME/.cursor" "$HOME/.codex"
  run_capture "$ROOT/bin/install"
  assert_exit 0
  assert_json "$(codex_path)" "$expected"
  expected=$(claude_created)
  assert_json "$(settings_path)" "$expected"
  assert_created
  assert_stdout_trimmed "claude: $(settings_path)
codex: $(codex_path)
$CODEX_NOTE
cursor: $(hooks_path)"

  # ~/.codex missing: Codex is left alone.
  fresh_home
  mkdir -p "$HOME/.claude" "$HOME/.cursor"
  run_capture "$ROOT/bin/install"
  assert_exit 0
  assert_missing "$HOME/.codex"
  assert_stdout_trimmed "claude: $(settings_path)
cursor: $(hooks_path)"
}

run_tests \
  test_install_creates \
  test_install_empty_object \
  test_install_appends \
  test_install_keeps_non_object \
  test_install_idempotent \
  test_install_registers_approval_idempotent \
  test_install_invalid_json \
  test_install_hooks_json_is_directory \
  test_install_cursor_is_file \
  test_install_mv_fails \
  test_install_via_symlink \
  test_install_bad_version \
  test_install_root_array \
  test_install_hooks_not_object \
  test_install_stop_not_array \
  test_install_bool_version \
  test_install_no_jq \
  test_install_cleans_tmp_on_mv_failure \
  test_install_removes_old_entries \
  test_install_removes_old_idempotent \
  test_install_keeps_unrelated \
  test_install_keeps_current_entry \
  test_install_claude_creates \
  test_install_claude_empty_file \
  test_install_blank_file \
  test_install_keeps_mode \
  test_install_repeated_agent \
  test_install_claude_merges \
  test_install_claude_idempotent \
  test_install_claude_finds_command_in_any_group \
  test_install_claude_removes_stale \
  test_install_claude_keeps_unrelated \
  test_install_claude_keeps_non_object \
  test_install_claude_invalid \
  test_install_claude_path_with_quote \
  test_install_detects_agents \
  test_install_unknown_agent \
  test_install_invalid_agent_name \
  test_install_one_fails_other_continues \
  test_install_prints_agents \
  test_install_claude_mv_fails \
  test_install_codex_creates \
  test_install_codex_empty_file \
  test_install_codex_merges_idempotent \
  test_install_codex_removes_stale \
  test_install_codex_invalid \
  test_install_detects_codex
