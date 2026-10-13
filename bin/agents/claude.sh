# Claude Code adapter. Sourced by notify and install; do not run it.
AGENT_LABEL=Claude
# Notification fires six seconds after the prompt appears, so it is up already.
AGENT_PROMPT_APPEARS_LATER=0
AGENT_CONFIG=.claude/settings.json
AGENT_CONFIG_SHAPE=nested

# One line per hook: the event name, a tab, and the matcher (empty for none).
agent_hooks() {
  printf '%s\t%s\n' Stop '' StopFailure '' Notification permission_prompt
}

# agent_parse EVENT INPUT
# Sets kind, session, folder, detail and title. An unknown event leaves kind empty.
agent_parse() {
  local event=$1 input=$2 object= type=
  kind= session= folder= detail= title=
  case $event in
    Stop | StopFailure | Notification) ;;
    *) return 0 ;;
  esac
  # The folder is the working directory; the core takes its last part.
  # @sh quotes every value, so the eval runs nothing from the payload.
  eval "$(printf '%s' "$input" | jq -r '
    objects |
    @sh "object=1",
    @sh "type=\(.notification_type | strings // "")",
    @sh "session=\(.session_id | strings // "")",
    @sh "folder=\(.cwd | strings // "")"
  ' 2>/dev/null)"
  [ "$object" = 1 ] || return 0
  case $event in
    Stop) kind=finished title="$AGENT_LABEL finished" ;;
    StopFailure) kind=failed title="$AGENT_LABEL hit an error" ;;
    Notification)
      # Approvals and questions both arrive as permission_prompt. detail stays
      # empty, so the body is the folder. Other types are ignored, in case the
      # matcher is edited by hand.
      if [ "$type" = permission_prompt ]; then
        kind=attention title="$AGENT_LABEL is waiting for you"
      fi
      ;;
  esac
}

# agent_prompt_on_screen SCREEN DETAIL
# True when one of the last three lines of the pane text that are not blank
# contains "Esc to cancel", the footer of every prompt in Claude Code 2.1.294.
# Three lines, because a narrow pane wraps the footer. The same words further
# up, in the conversation, do not count.
agent_prompt_on_screen() {
  local line third= second= last=
  while IFS= read -r line; do
    if [[ $line == *[![:space:]]* ]]; then
      third=$second second=$last last=$line
    fi
  done <<<"$1"
  [[ $third$'\n'$second$'\n'$last == *'Esc to cancel'* ]]
}
