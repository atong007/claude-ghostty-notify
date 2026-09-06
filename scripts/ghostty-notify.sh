#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Read hook JSON from stdin
RAW=$(cat)

# Only notify for actionable types (permission prompts, input dialogs, task completion)
# Stop hook has no notification_type; fall back to hook_event_name ("Stop")
NOTIF_TYPE=$(echo "$RAW" | json_val "notification_type")
if [ -z "$NOTIF_TYPE" ]; then
    NOTIF_TYPE=$(echo "$RAW" | json_val "hook_event_name")
fi
case "$NOTIF_TYPE" in
    permission_prompt|elicitation_dialog|Stop) ;;
    *) exit 0 ;;
esac

# Stop events carry no message; give the notification a sensible body
if [ "$NOTIF_TYPE" = "Stop" ] && [ -z "$(echo "$RAW" | json_val "message")" ]; then
    RAW=$(echo "$RAW" | json_set "message" "✅ 任务完成")
fi

TRANSCRIPT=$(echo "$RAW" | json_val "transcript_path")

# Count user messages before delay (to detect if user responded, not just Claude writing)
USER_MSGS_BEFORE=0
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    USER_MSGS_BEFORE=$(grep -c '"type":"user"' "$TRANSCRIPT" 2>/dev/null || true)
fi

# Delay — gives user time to respond before notification fires
sleep 3

# Check if Ghostty is focused AND the active tab is THIS session's terminal
SESSION_ID=$(echo "$RAW" | json_val "session_id")
FRONTMOST=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || true)
if [ "$(printf '%s' "$FRONTMOST" | tr '[:upper:]' '[:lower:]')" = "ghostty" ]; then
    # Check by terminal UUID from SQLite store
    ensure_db
    SAVED_TID=$(sqlite3 "$NOTIFY_DB" "SELECT terminal_uuid FROM sessions WHERE session_id = '$SESSION_ID';" 2>/dev/null || true)
    if [ -n "$SAVED_TID" ]; then
        ACTIVE_TID=$(osascript -e '
            tell application "Ghostty"
                try
                    return id of focused terminal of selected tab of first window
                end try
                return ""
            end tell' 2>/dev/null || true)
        if [ "$ACTIVE_TID" = "$SAVED_TID" ]; then
            exit 0
        fi
    fi
fi

# Check if user submitted a new message during the delay
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    USER_MSGS_AFTER=$(grep -c '"type":"user"' "$TRANSCRIPT" 2>/dev/null || true)
    if [ "$USER_MSGS_AFTER" -gt "$USER_MSGS_BEFORE" ]; then
        exit 0
    fi
fi

# Enrich message with actual tool/command from transcript
ENRICHED_MSG=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    ENRICHED_MSG=$(extract_last_tool "$TRANSCRIPT")
fi

if [ -n "$ENRICHED_MSG" ]; then
    RAW=$(echo "$RAW" | json_set "message" "$ENRICHED_MSG")
fi

# Base64 encode and launch
INPUT=$(echo "$RAW" | base64)

pkill -f "ClaudeNotify.app" 2>/dev/null || true
open -n -a "$NOTIFY_APP" --args "$INPUT" &
exit 0
