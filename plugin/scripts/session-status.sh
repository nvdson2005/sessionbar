#!/bin/bash
# sessionbar hook: records the state of this Claude Code session so the
# menu bar plugin can show it. Registered for every lifecycle event in
# ../hooks/hooks.json.
#
# Contract: must never block or break Claude Code. No stdout, always exit 0.
set -u

command -v jq >/dev/null 2>&1 || exit 0

STATE_DIR="${SESSIONBAR_DIR:-$HOME/.local/state/sessionbar}"
CONFIG_FILE="${SESSIONBAR_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/sessionbar/config}"

input=$(cat) || exit 0
[ -n "$input" ] || exit 0

IFS=$'\t' read -r event sid cwd < <(
  jq -r '[.hook_event_name // "", .session_id // "", .cwd // ""] | @tsv' <<<"$input" 2>/dev/null
) || exit 0

[ -n "$event" ] && [ -n "$sid" ] || exit 0
# session_id becomes a filename: only allow safe characters.
case "$sid" in *[!A-Za-z0-9_-]*) exit 0 ;; esac

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
file="$STATE_DIR/$sid.json"

if [ "$event" = "SessionEnd" ]; then
  rm -f "$file"
  exit 0
fi

# Walk up the process tree to find the Claude Code process, so the menu bar
# can drop sessions whose process has died without sending SessionEnd.
find_claude_pid() {
  local pid=$PPID comm i
  for i in 1 2 3 4 5 6; do
    [ "$pid" -gt 1 ] 2>/dev/null || break
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    case "${comm##*/}" in [Cc]laude*) echo "$pid"; return ;; esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || break
  done
  echo 0
}

# Desktop notification through SwiftBar's URL scheme. Clicking it runs
# `sessionbar focus <id>`, which brings the session's terminal tab forward.
notify() {
  local title=$1 body=$2 silent=false sb url opener
  grep -qx 'notify=off' "$CONFIG_FILE" 2>/dev/null && return 0
  grep -qx 'sound=off' "$CONFIG_FILE" 2>/dev/null && silent=true
  if [ -n "${SESSIONBAR_OPEN:-}" ]; then
    opener=$SESSIONBAR_OPEN # tests
  else
    pgrep -xq SwiftBar || return 0 # don't launch SwiftBar just to notify
    opener="open -g"
  fi
  sb=$(command -v sessionbar 2>/dev/null || true)
  url=$(jq -rn --arg t "$title" --arg b "$body" --arg sb "$sb" --arg sid "$sid" --arg silent "$silent" '
    "swiftbar://notify?plugin=sessionbar&title=\($t | @uri)&body=\($b | @uri)&silent=\($silent)"
    + (if $sb != "" then "&bash=\($sb | @uri)&param1=focus&param2=\($sid | @uri)&terminal=false" else "" end)
  ') || return 0
  $opener "$url"
}

prev='{}'
if [ -s "$file" ]; then
  prev=$(jq -c 'if type == "object" then . else {} end' "$file" 2>/dev/null) || prev='{}'
fi

IFS=$'\t' read -r pid prev_state has_term < <(
  jq -r '[(.pid // 0), (.state // "-"), has("term")] | @tsv' <<<"$prev" 2>/dev/null
) || { pid=0; prev_state=-; has_term=false; }

if [ -n "${SESSIONBAR_PID:-}" ]; then
  pid=$SESSIONBAR_PID
elif [ "$pid" = "0" ]; then
  pid=$(find_claude_pid)
fi

# Terminal identity, captured once per session: used by `sessionbar focus`.
term='null'
if [ "$has_term" != "true" ]; then
  tty=""
  if [ "$pid" -gt 0 ] 2>/dev/null; then
    tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$tty" in "" | "??") tty="" ;; *) tty="/dev/$tty" ;; esac
  fi
  iterm=${ITERM_SESSION_ID:-}
  iterm=${iterm#*:} # "w0t1p0:<UUID>" → UUID, matches iTerm2's session unique id
  term=$(jq -nc --arg app "${TERM_PROGRAM:-}" --arg tty "$tty" \
    --arg iterm "$iterm" --arg tmux "${TMUX:+1}" --arg bundle "${__CFBundleIdentifier:-}" \
    '{app: $app, bundle: $bundle, tty: $tty, iterm_session: $iterm, tmux: ($tmux == "1")}') || term='null'
fi

# Git branch: refreshed on turn boundaries only, keeping tool events fast.
branch_json='null'
case "$event" in
  SessionStart | UserPromptSubmit | Stop)
    if [ -n "$cwd" ] && [ -d "$cwd" ]; then
      branch_json=$(git -C "$cwd" branch --show-current 2>/dev/null | jq -R . 2>/dev/null) || branch_json='null'
      [ -n "$branch_json" ] || branch_json='""'
    fi
    ;;
esac

tmp="$file.tmp.$$"
jq -c --argjson prev "$prev" --argjson now "$(date +%s)" --argjson pid "$pid" \
  --argjson term "$term" --argjson branch "$branch_json" '
  . as $in
  | $in.hook_event_name as $e
  | (if $e == "Notification" then
       if ($in.notification_type == "idle_prompt")
          or (($in.message // "") | test("waiting for your input"; "i"))
       then {state: "idle", detail: ""}
       else {state: "waiting", detail: ($in.message // "Needs attention")}
       end
     elif $e == "PreToolUse" or $e == "PostToolUse" then {state: "working", detail: ($in.tool_name // "")}
     elif $e == "UserPromptSubmit" then {state: "working", detail: "Thinking", turn_started_at: $now}
     elif $e == "Stop" then {state: "idle", detail: "Done"}
     elif $e == "SessionStart" then {state: "idle", detail: ""}
     else empty
     end) as $s
  | $prev + $s + {
      session_id: $in.session_id,
      cwd: ($in.cwd // $prev.cwd // ""),
      event: $e,
      pid: $pid,
      updated_at: $now,
      started_at: ($prev.started_at // $now),
      waiting_since: (if $s.state != "waiting" then null
                      elif $prev.state == "waiting" then ($prev.waiting_since // $now)
                      else $now end),
      branch: (if $branch == null then $prev.branch else $branch end),
      term: ($prev.term // $term)
    }
' <<<"$input" >"$tmp" 2>/dev/null

if [ -s "$tmp" ]; then
  mv -f "$tmp" "$file"
else
  rm -f "$tmp"
  exit 0
fi

if [ "$event" = "Notification" ] && [ "$prev_state" != "waiting" ]; then
  IFS=$'\t' read -r new_state message < <(jq -r '[.state, (.detail // "")] | @tsv' "$file" 2>/dev/null)
  if [ "${new_state:-}" = "waiting" ]; then
    project=${cwd%/}; project=${project##*/}
    (notify "${project:-Claude} needs you" "${message:-Needs attention}") >/dev/null 2>&1 &
  fi
fi
exit 0
