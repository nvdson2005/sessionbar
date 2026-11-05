#!/bin/bash
# Smoke tests: feed fake hook payloads into the hook script, check state files
# and CLI output. Uses temp state/config folders; never touches ~/.claude.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$ROOT/plugin/scripts/session-status.sh"
CLI="$ROOT/bin/sessionbar"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export SESSIONBAR_DIR="$TMP/state"
export SESSIONBAR_CONFIG="$TMP/config"
export SESSIONBAR_PID=0 # skip process detection in tests
# Capture notifications instead of opening SwiftBar URLs.
NOTIFY_LOG="$TMP/notify.log"
printf '#!/bin/bash\necho "$1" >> "%s"\n' "$NOTIFY_LOG" >"$TMP/fake-open"
chmod +x "$TMP/fake-open"
export SESSIONBAR_OPEN=/usr/bin/true # discard; the notifications section swaps in fake-open
# Pretend to run inside iTerm2.
export TERM_PROGRAM=iTerm.app ITERM_SESSION_ID="w0t1p0:ABC-123" __CFBundleIdentifier=com.googlecode.iterm2
unset TMUX

# A git repo so branch detection has something to find.
REPO="$TMP/proj-a"
git init -q -b feat/menu "$REPO"

pass=0 fail=0
ok() { echo "  ✓ $1"; pass=$((pass + 1)); }
bad() { echo "  ✗ $1"; fail=$((fail + 1)); }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

hook() { echo "$1" | "$HOOK"; }
state() { jq -r ".$2" "$SESSIONBAR_DIR/$1.json"; }
ev() { printf '{"hook_event_name":"%s","session_id":"%s","cwd":"%s"%s}' "$1" "$2" "$3" "${4:-}"; }
# Notifications are sent in the background; give them a moment to land.
notify_count() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$NOTIFY_LOG" ] && break; sleep 0.1; done
  sleep 0.2
  [ -f "$NOTIFY_LOG" ] && wc -l <"$NOTIFY_LOG" | tr -d ' ' || echo 0
}

echo "hook: states"
hook "$(ev SessionStart s1 "$REPO" ',"source":"startup"')"
expect "SessionStart → idle" "$(state s1 state)" "idle"
started=$(state s1 started_at)

hook "$(ev UserPromptSubmit s1 "$REPO" ',"prompt":"hi"')"
expect "UserPromptSubmit → working" "$(state s1 state)" "working"
expect "turn_started_at set" "$([ "$(state s1 turn_started_at)" != null ] && echo yes)" "yes"

hook "$(ev PreToolUse s1 "$REPO" ',"tool_name":"Bash","tool_input":{}')"
expect "PreToolUse detail = tool" "$(state s1 detail)" "Bash"

hook "$(ev Notification s1 "$REPO" ',"message":"Claude needs your permission to use Bash"')"
expect "permission Notification → waiting" "$(state s1 state)" "waiting"
expect "waiting_since set" "$([ "$(state s1 waiting_since)" != null ] && echo yes)" "yes"

hook "$(ev PostToolUse s1 "$REPO" ',"tool_name":"Bash"')"
expect "PostToolUse → working again" "$(state s1 state)" "working"
expect "waiting_since cleared" "$(state s1 waiting_since)" "null"

hook "$(ev Stop s1 "$REPO")"
expect "Stop → idle" "$(state s1 state)" "idle"

hook "$(ev Notification s1 "$REPO" ',"message":"Claude is waiting for your input"')"
expect "idle Notification stays idle" "$(state s1 state)" "idle"
expect "started_at preserved" "$(state s1 started_at)" "$started"

echo "hook: context"
expect "git branch recorded" "$(state s1 branch)" "feat/menu"
expect "terminal app recorded" "$(state s1 term.app)" "iTerm.app"
expect "iTerm session id recorded" "$(state s1 term.iterm_session)" "ABC-123"
expect "app bundle recorded" "$(state s1 term.bundle)" "com.googlecode.iterm2"
TERM_PROGRAM=Apple_Terminal hook "$(ev PreToolUse s1 "$REPO" ',"tool_name":"Read"')"
expect "terminal captured once (not overwritten)" "$(state s1 term.app)" "iTerm.app"

hook "$(ev SessionStart nogit /tmp)"
expect "no repo → empty branch" "$(state nogit branch)" ""
rm -f "$SESSIONBAR_DIR/nogit.json"

echo "hook: robustness"
big=$(head -c 2000000 /dev/zero | tr '\0' 'x')
printf '{"hook_event_name":"PostToolUse","session_id":"s1","cwd":"%s","tool_name":"Read","tool_response":"%s"}' "$REPO" "$big" | "$HOOK"
expect "2MB payload handled" "$(state s1 detail)" "Read"

hook "$(ev SessionStart ../evil /tmp)"
expect "unsafe session_id ignored" "$(ls "$SESSIONBAR_DIR" | wc -l | tr -d ' ')" "1"

out=$(echo 'not json' | "$HOOK"; echo "rc=$?")
expect "garbage input → silent exit 0" "$out" "rc=0"

out=$(env -u ITERM_SESSION_ID -u TERM_PROGRAM bash -c "echo '$(ev SessionStart s9 /tmp)' | '$HOOK'"; echo "rc=$?")
expect "works outside iTerm2 (set -u safe)" "$out" "rc=0"
expect "  …and records state" "$(state s9 state)" "idle"
rm -f "$SESSIONBAR_DIR/s9.json"

echo "hook: notifications"
export SESSIONBAR_OPEN="$TMP/fake-open"
hook "$(ev PostToolUse s1 "$REPO" ',"tool_name":"Bash"')" # leave waiting first
rm -f "$NOTIFY_LOG"
hook "$(ev Notification s1 "$REPO" ',"message":"Claude needs your permission to use Bash"')"
expect "notifies on transition to waiting" "$(notify_count)" "1"
grep -q 'title=proj-a%20needs%20you' "$NOTIFY_LOG" && ok "notification title names the project" || bad "notification title"
grep -q 'param1=focus&param2=s1' "$NOTIFY_LOG" && ok "notification click focuses the session" || bad "notification click action"
hook "$(ev Notification s1 "$REPO" ',"message":"Claude needs your permission to use Bash"')"
expect "no repeat while still waiting" "$(notify_count)" "1"

hook "$(ev PostToolUse s1 "$REPO" ',"tool_name":"Bash"')"
"$CLI" config notify off >/dev/null
rm -f "$NOTIFY_LOG"
hook "$(ev Notification s1 "$REPO" ',"message":"Claude needs your permission to use Bash"')"
expect "notify=off suppresses" "$(notify_count)" "0"
"$CLI" config notify on >/dev/null

echo "cli: config"
expect "config defaults/readback" "$("$CLI" config | tr '\n' ' ')" "notify=on sound=on "
"$CLI" config sound off >/dev/null
expect "config set sound off" "$("$CLI" config | tr '\n' ' ')" "notify=on sound=off "
expect "config rejects bad key" "$("$CLI" config color red 2>&1 >/dev/null || true)" "sessionbar: unknown setting 'color' (use: notify, sound)"
"$CLI" config sound on >/dev/null

echo "cli: status + swiftbar"
hook "$(ev SessionStart s2 "/tmp/proj b|weird")"
hook "$(ev UserPromptSubmit s2 "/tmp/proj b|weird")"
hook "$(ev SessionStart s3 /tmp/idle-proj)"
expect "status --json count" "$("$CLI" status --json | jq length)" "3"
expect "waiting sorted first" "$("$CLI" status --json | jq -r '.[0].session_id')" "s1"

sb=$("$CLI" swiftbar)
title=$(head -1 <<<"$sb")
expect "title: one dot per session" "$(grep -o '●' <<<"$title" | wc -l | tr -d ' ')" "3"
grep -q 'ansi=true' <<<"$title" && ok "title uses ansi colors" || bad "title ansi"
[[ $title == $'\e[38;5;214m●'* ]] && ok "title: waiting (orange) dot first" || bad "title: orange dot first"
grep -q '^NEEDS YOU (1)' <<<"$sb" && ok "group: NEEDS YOU" || bad "group NEEDS YOU"
grep -q '^WORKING (1)' <<<"$sb" && ok "group: WORKING" || bad "group WORKING"
grep -q '^IDLE (1)' <<<"$sb" && ok "group: IDLE" || bad "group IDLE"
grep -q 'feat/menu' <<<"$sb" && ok "row shows branch" || bad "row branch"
grep -q 'param1=focus param2=s1' <<<"$sb" && ok "row click focuses session" || bad "row focus action"
grep -q 'alternate=true' <<<"$sb" && ok "⌥ alternate row present" || bad "alternate row"
grep -q 'tooltip=' <<<"$sb" && ok "rows have tooltips" || bad "tooltips"
if grep -q 'proj b|weird' <<<"$sb"; then bad "pipe in path not sanitized"; else ok "pipe in path sanitized"; fi
grep -q '^Notify when a session needs you .*checked=true' <<<"$sb" && ok "notify toggle checked" || bad "notify toggle"

for i in 4 5 6 7 8; do hook "$(ev SessionStart "x$i" /tmp/p$i)"; done
title=$("$CLI" swiftbar | head -1)
expect "title caps at 6 dots" "$(grep -o '●' <<<"$title" | wc -l | tr -d ' ')" "6"
grep -q '+2' <<<"$title" && ok "title shows +N overflow" || bad "overflow +N"
rm -f "$SESSIONBAR_DIR"/x*.json

jq '.waiting_since = 1' "$SESSIONBAR_DIR/s1.json" >"$TMP/x" && mv "$TMP/x" "$SESSIONBAR_DIR/s1.json"
t=$(( $(date +%s) / 6 * 6 )) # even 3s bucket
a=$(SESSIONBAR_NOW=$t "$CLI" swiftbar | head -1 | grep -o '[●○]' | head -1)
b=$(SESSIONBAR_NOW=$((t + 3)) "$CLI" swiftbar | head -1 | grep -o '[●○]' | head -1)
expect "waiting > 2min blinks" "$a$b" "●○"

echo "cli: focus + clean"
expect "focus rejects bad id" "$("$CLI" focus '../x' 2>&1 || true)" "sessionbar: usage: sessionbar focus <session_id>"
expect "focus unknown session" "$("$CLI" focus nope 2>&1 || true)" "sessionbar: no such session: nope"

jq '.pid = 999999' "$SESSIONBAR_DIR/s2.json" >"$TMP/x" && mv "$TMP/x" "$SESSIONBAR_DIR/s2.json"
jq '.updated_at = 1' "$SESSIONBAR_DIR/s3.json" >"$TMP/x" && mv "$TMP/x" "$SESSIONBAR_DIR/s3.json"
expect "clean removes dead + stale" "$("$CLI" clean)" "removed 2 stale session(s)"
rm -f "$SESSIONBAR_DIR/s1.json"
expect "empty swiftbar title" "$("$CLI" swiftbar | head -1)" " | sfimage=sparkle sfcolor=#8E8E93"

hook "$(ev SessionStart s4 /tmp/c)"
hook "$(ev SessionEnd s4 /tmp/c ',"reason":"exit"')"
expect "SessionEnd removes file" "$([ -e "$SESSIONBAR_DIR/s4.json" ] && echo yes || echo no)" "no"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
