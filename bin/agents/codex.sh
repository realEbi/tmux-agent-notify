# Codex CLI adapter. Sourced by notify and install; do not run it.
# Measured on Codex CLI 0.162.1.
AGENT_LABEL=Codex
# PermissionRequest runs just before the approval screen is drawn.
AGENT_PROMPT_APPEARS_LATER=1
AGENT_CONFIG=.codex/hooks.json
AGENT_CONFIG_SHAPE=nested
# Printed by the installer after this agent's line.
AGENT_INSTALL_NOTE='Codex skips new hooks until you trust them: start codex and choose "Trust all and continue", or run /hooks inside Codex.'

# One line per hook: the event name, a tab, and the matcher (none for Codex).
# Interrupt is left out, so a turn you interrupt or deny with Esc is silent.
agent_hooks() {
  printf '%s\t\n' Stop PermissionRequest
}

# agent_parse EVENT INPUT
# Sets kind, session, folder, detail and title. An unknown event leaves kind empty.
agent_parse() {
  local event=$1 input=$2 object= tool= command= line file=
  kind= session= folder= detail= title=
  case $event in
    Stop | PermissionRequest) ;;
    *) return 0 ;;
  esac
  # The folder is the working directory; the core takes its last part, and
  # agent_locate looks for the session by the whole path.
  # @sh quotes every value, so the eval runs nothing from the payload.
  eval "$(printf '%s' "$input" | jq -r '
    objects |
    ((.tool_input | objects | .command) // null) as $command |
    @sh "object=1",
    @sh "session=\(.session_id | strings // "")",
    @sh "folder=\(.cwd | strings // "")",
    @sh "tool=\(.tool_name | strings // "")",
    @sh "command=\($command | if type == "array" then map(tostring) | join(" ") else strings // "" end)"
  ' 2>/dev/null)"
  [ "$object" = 1 ] || return 0
  case $event in
    Stop) kind=finished title="$AGENT_LABEL finished" ;;
    PermissionRequest)
      kind=attention title="$AGENT_LABEL needs approval"
      if [ "$tool" = apply_patch ]; then
        # The command is the whole patch. Name the first file in it.
        while IFS= read -r line; do
          case $line in
            '*** Add File: '* | '*** Update File: '* | '*** Delete File: '*)
              file=${line#*: }
              break
              ;;
          esac
        done <<<"$command"
        detail="Edit ${file##*/}"
        [ -n "${file##*/}" ] || detail='Edit files'
      else
        # A shell command, cut to its first line. Other tools carry no
        # command, so their name is shown.
        detail=${command%%$'\n'*}
        [ -n "$detail" ] || detail=$tool
      fi
      ;;
  esac
}

# agent_prompt_on_screen SCREEN DETAIL
# True when one of the last three lines of the pane text that are not blank
# contains "enter to confirm or esc to cancel", the last line of the approval
# screen for shell commands and file edits. Three lines, because a narrow pane
# wraps it. The same words further up, in the conversation, do not count.
agent_prompt_on_screen() {
  local line third= second= last=
  while IFS= read -r line; do
    if [[ $line == *[![:space:]]* ]]; then
      third=$second second=$last last=$line
    fi
  done <<<"$1"
  [[ $third$'\n'$second$'\n'$last == *'enter to confirm or esc to cancel'* ]]
}

# True for the command line of a Codex session running in a terminal: a path
# that ends in "codex", and not the background daemon.
codex_is_client() {
  local name='(^|/)codex( |$)'
  [[ $1 =~ $name ]] && [[ " $1 " != *' app-server '* ]]
}

# Print a directory as the system knows it, so /tmp and /private/tmp/ compare
# equal. A directory that cannot be entered only loses its trailing slashes.
codex_dir() {
  local dir=$1
  (cd -- "$dir" 2>/dev/null && pwd -P) && return 0
  while [[ $dir == ?*/ ]]; do
    dir=${dir%/}
  done
  printf '%s\n' "$dir"
}

# agent_locate
# Called by notify after agent_parse. Codex runs hooks inside a shared
# background daemon by default, so TMUX, TMUX_PANE and __CFBundleIdentifier
# are the daemon's: those of wherever it was first started. When the hook's
# parent is that daemon, take the three from the Codex session whose working
# directory is the payload's cwd. Nothing else links a hook to its session, so
# the first session found in that folder is used. With no such session, or
# with a parent that is the session itself (codex --no-daemon), the hook's own
# environment is kept.
agent_locate() {
  local parent want listing pid tty cmd pids= line found= environment token
  local tmux= pane= bundle=
  local digits='^[0-9]+$' pane_id='^%[0-9]+$' tmux_value='^/.*,[0-9]+,[0-9]+$'
  local -a tokens

  parent=$(ps -o command= -p "$PPID" 2>/dev/null)
  case " $parent " in
    *codex*' app-server '*) ;;
    *) return 0 ;;
  esac
  [ -n "$folder" ] || return 0
  want=$(codex_dir "$folder")

  # Sessions run in a terminal; "??" in the tty column means none.
  listing=$(ps -axo pid=,tty=,command= 2>/dev/null)
  while read -r pid tty cmd; do
    if [[ $pid =~ $digits ]] && [ "$tty" != '??' ] && codex_is_client "$cmd"; then
      pids="$pids,$pid"
    fi
  done <<<"$listing"
  pids=${pids#,}
  [ -n "$pids" ] || return 0

  # lsof prints three lines for each process: p<pid>, fcwd and n<directory>.
  # It may live in /usr/sbin, which is not always on PATH.
  listing=$(PATH="$PATH:/usr/sbin" lsof -a -d cwd -p "$pids" -Fpn 2>/dev/null)
  pid=
  while IFS= read -r line; do
    case $line in
      p*) pid=${line#p} ;;
      n*)
        if [ -n "$pid" ] && [ "$(codex_dir "${line#n}")" = "$want" ]; then
          found=$pid
          break
        fi
        ;;
    esac
  done <<<"$listing"
  [ -n "$found" ] || return 0

  # "ps eww" prints the command, then the environment as KEY=value words. The
  # values wanted here hold no spaces. The last one of each name wins, because
  # the environment comes after the arguments.
  environment=$(ps eww -o command= -p "$found" 2>/dev/null)
  [ -n "$environment" ] || return 0
  IFS=' ' read -r -a tokens <<<"$environment"
  for token in ${tokens[@]+"${tokens[@]}"}; do
    case $token in
      TMUX=*) tmux=${token#TMUX=} ;;
      TMUX_PANE=*) pane=${token#TMUX_PANE=} ;;
      __CFBundleIdentifier=*) bundle=${token#__CFBundleIdentifier=} ;;
    esac
  done

  # A session outside tmux has neither value, and gets no notification. Values
  # that do not look right are treated the same way.
  if [[ $pane =~ $pane_id ]] && [[ $tmux =~ $tmux_value ]]; then
    export TMUX="$tmux" TMUX_PANE="$pane"
  else
    unset TMUX TMUX_PANE
  fi
  if [ -n "$bundle" ]; then
    export __CFBundleIdentifier="$bundle"
  else
    unset __CFBundleIdentifier
  fi
}
