#!/bin/bash
# Smoke tests: feed fake hook payloads into the hook script, check state files
# and CLI output. Uses a temp state dir; never touches ~/.claude.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$ROOT/plugin/scripts/session-status.sh"
CLI="$ROOT/bin/sessionbar"
export SESSIONBAR_DIR
SESSIONBAR_DIR=$(mktemp -d)
export SESSIONBAR_PID=0 # skip process detection in tests
trap 'rm -rf "$SESSIONBAR_DIR"' EXIT

pass=0 fail=0
ok() { echo "  ✓ $1"; pass=$((pass + 1)); }
bad() { echo "  ✗ $1"; fail=$((fail + 1)); }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

hook() { echo "$1" | "$HOOK"; }
state() { jq -r ".$2" "$SESSIONBAR_DIR/$1.json"; }

echo "hook"
hook '{"hook_event_name":"SessionStart","session_id":"s1","cwd":"/tmp/proj-a","source":"startup"}'
expect "SessionStart → idle" "$(state s1 state)" "idle"
started=$(state s1 started_at)

hook '{"hook_event_name":"UserPromptSubmit","session_id":"s1","cwd":"/tmp/proj-a","prompt":"hi"}'
expect "UserPromptSubmit → working" "$(state s1 state)" "working"

hook '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/tmp/proj-a","tool_name":"Bash","tool_input":{}}'
expect "PreToolUse detail = tool" "$(state s1 detail)" "Bash"

hook '{"hook_event_name":"Notification","session_id":"s1","cwd":"/tmp/proj-a","message":"Claude needs your permission to use Bash"}'
expect "permission Notification → waiting" "$(state s1 state)" "waiting"

hook '{"hook_event_name":"PostToolUse","session_id":"s1","cwd":"/tmp/proj-a","tool_name":"Bash"}'
expect "PostToolUse → working again" "$(state s1 state)" "working"

hook '{"hook_event_name":"Stop","session_id":"s1","cwd":"/tmp/proj-a"}'
expect "Stop → idle" "$(state s1 state)" "idle"

hook '{"hook_event_name":"Notification","session_id":"s1","cwd":"/tmp/proj-a","message":"Claude is waiting for your input"}'
expect "idle Notification stays idle" "$(state s1 state)" "idle"
expect "started_at preserved" "$(state s1 started_at)" "$started"

big=$(head -c 2000000 /dev/zero | tr '\0' 'x')
printf '{"hook_event_name":"PostToolUse","session_id":"s1","cwd":"/tmp/proj-a","tool_name":"Read","tool_response":"%s"}' "$big" | "$HOOK"
expect "2MB payload handled" "$(state s1 detail)" "Read"

hook '{"hook_event_name":"SessionStart","session_id":"../evil","cwd":"/tmp"}'
expect "unsafe session_id ignored" "$(ls "$SESSIONBAR_DIR" | wc -l | tr -d ' ')" "1"

out=$(echo 'not json' | "$HOOK"; echo "rc=$?")
expect "garbage input → silent exit 0" "$out" "rc=0"

hook '{"hook_event_name":"SessionStart","session_id":"s2","cwd":"/tmp/proj b|weird"}'
hook '{"hook_event_name":"Notification","session_id":"s2","cwd":"/tmp/proj b|weird","message":"needs permission"}'

echo "cli"
expect "status --json count" "$("$CLI" status --json | jq length)" "2"
expect "waiting sorted first" "$("$CLI" status --json | jq -r '.[0].session_id')" "s2"

sb=$("$CLI" swiftbar)
expect "swiftbar title shows waiting" "$(head -1 <<<"$sb")" "1/2 | sfimage=exclamationmark.bubble.fill sfcolor=#FF9F0A"
if grep -q 'proj b¦\|proj b|weird —' <<<"$sb"; then bad "pipe in path not sanitized"; else ok "pipe in path sanitized"; fi

jq '.pid = 999999' "$SESSIONBAR_DIR/s2.json" >"$SESSIONBAR_DIR/x" && mv "$SESSIONBAR_DIR/x" "$SESSIONBAR_DIR/s2.json"
jq '.updated_at = 1' "$SESSIONBAR_DIR/s1.json" >"$SESSIONBAR_DIR/x" && mv "$SESSIONBAR_DIR/x" "$SESSIONBAR_DIR/s1.json"
expect "clean removes dead + stale" "$("$CLI" clean)" "removed 2 stale session(s)"
expect "empty swiftbar title" "$("$CLI" swiftbar | head -1)" " | sfimage=sparkle sfcolor=#8E8E93"

hook '{"hook_event_name":"SessionStart","session_id":"s3","cwd":"/tmp/c"}'
hook '{"hook_event_name":"SessionEnd","session_id":"s3","cwd":"/tmp/c","reason":"exit"}'
expect "SessionEnd removes file" "$([ -e "$SESSIONBAR_DIR/s3.json" ] && echo yes || echo no)" "no"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
