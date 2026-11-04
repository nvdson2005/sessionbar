#!/bin/bash
# sessionbar hook: records the state of this Claude Code session so the
# menu bar plugin can show it. Registered for every lifecycle event in
# ../hooks/hooks.json.
#
# Contract: must never block or break Claude Code. No stdout, always exit 0.
set -u

command -v jq >/dev/null 2>&1 || exit 0

STATE_DIR="${SESSIONBAR_DIR:-$HOME/.local/state/sessionbar}"

input=$(cat) || exit 0
[ -n "$input" ] || exit 0

IFS=$'\t' read -r event sid < <(
  jq -r '[.hook_event_name // "", .session_id // ""] | @tsv' <<<"$input" 2>/dev/null
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

prev='{}'
if [ -s "$file" ]; then
  prev=$(jq -c 'if type == "object" then . else {} end' "$file" 2>/dev/null) || prev='{}'
fi

pid=$(jq -r '.pid // 0' <<<"$prev" 2>/dev/null) || pid=0
if [ -n "${SESSIONBAR_PID:-}" ]; then
  pid=$SESSIONBAR_PID
elif [ "$pid" = "0" ]; then
  pid=$(find_claude_pid)
fi

tmp="$file.tmp.$$"
jq -c --argjson prev "$prev" --argjson now "$(date +%s)" --argjson pid "$pid" '
  . as $in
  | $in.hook_event_name as $e
  | (if $e == "Notification" then
       if ($in.notification_type == "idle_prompt")
          or (($in.message // "") | test("waiting for your input"; "i"))
       then {state: "idle", detail: ""}
       else {state: "waiting", detail: ($in.message // "Needs attention")}
       end
     elif $e == "PreToolUse" or $e == "PostToolUse" then {state: "working", detail: ($in.tool_name // "")}
     elif $e == "UserPromptSubmit" then {state: "working", detail: "Thinking"}
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
      started_at: ($prev.started_at // $now)
    }
' <<<"$input" >"$tmp" 2>/dev/null

if [ -s "$tmp" ]; then
  mv -f "$tmp" "$file"
else
  rm -f "$tmp"
fi
exit 0
