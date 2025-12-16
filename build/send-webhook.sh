#!/bin/sh

# send-webhook.sh - Sends webhook notifications with consistent JSON payload structure
# Usage: send-webhook.sh <event_type> [image_name] [image_tag] [image_id] [container_name] [container_id] [message] [error]

WEBHOOK_URL="${WEBHOOK_URL:-}"
WEBHOOK_TIMEOUT="${WEBHOOK_TIMEOUT:-10}"

# If webhook URL is not set, exit silently
if [ -z "$WEBHOOK_URL" ]; then
  exit 0
fi

EVENT_TYPE="$1"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EVENT_ID=$(date +%s%N | cut -b1-13)

# Generate consistent JSON payload based on event type
case "$EVENT_TYPE" in
  "gc_started")
    PAYLOAD=$(cat <<EOF
{
  "event_id": "${EVENT_ID}",
  "event_type": "gc_started",
  "timestamp": "${TIMESTAMP}",
  "details": {
    "message": "Docker garbage collection process has started"
  }
}
EOF
)
    ;;
    
  "gc_finished")
    TITLE="${2:-No actions taken}"
    IMAGE_COUNT="${3:-0}"
    CONTAINER_COUNT="${4:-0}"
    IMAGE_JSON_ARRAY="${5:-[]}"
    CONTAINER_JSON_ARRAY="${6:-[]}"
    MESSAGE="${7:-Docker garbage collection process has completed successfully}"
    
    # Escape title and message for JSON
    TITLE_ESC=$(printf '%s' "$TITLE" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
    MESSAGE_ESC=$(printf '%s' "$MESSAGE" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
    
    PAYLOAD=$(cat <<EOF
{
  "event_id": "${EVENT_ID}",
  "event_type": "gc_finished",
  "timestamp": "${TIMESTAMP}",
  "title": "${TITLE_ESC}",
  "details": {
    "message": "${MESSAGE_ESC}",
    "summary": {
      "image_count": ${IMAGE_COUNT},
      "container_count": ${CONTAINER_COUNT},
      "images": ${IMAGE_JSON_ARRAY},
      "containers": ${CONTAINER_JSON_ARRAY}
    }
  }
}
EOF
)
    ;;
    
  "gc_failed")
    ERROR_MSG="${8:-Docker garbage collection process failed}"
    PAYLOAD=$(cat <<EOF
{
  "event_id": "${EVENT_ID}",
  "event_type": "gc_failed",
  "timestamp": "${TIMESTAMP}",
  "details": {
    "message": "${ERROR_MSG}",
    "error": true
  }
}
EOF
)
    ;;
    
  "image_deleted")
    IMAGE_NAME="${2:-unknown}"
    IMAGE_TAG="${3:-}"
    IMAGE_ID="${4:-}"
    MESSAGE="${7:-Image ${IMAGE_NAME}${IMAGE_TAG:+:${IMAGE_TAG}} has been deleted}"
    
    PAYLOAD=$(cat <<EOF
{
  "event_id": "${EVENT_ID}",
  "event_type": "image_deleted",
  "timestamp": "${TIMESTAMP}",
  "details": {
    "image": {
      "name": "${IMAGE_NAME}",
      "tag": "${IMAGE_TAG}",
      "id": "${IMAGE_ID}"
    },
    "message": "${MESSAGE}"
  }
}
EOF
)
    ;;
    
  "container_deleted")
    CONTAINER_NAME="${5:-unknown}"
    CONTAINER_ID="${6:-}"
    MESSAGE="${7:-Container ${CONTAINER_NAME} has been deleted}"
    
    PAYLOAD=$(cat <<EOF
{
  "event_id": "${EVENT_ID}",
  "event_type": "container_deleted",
  "timestamp": "${TIMESTAMP}",
  "details": {
    "container": {
      "name": "${CONTAINER_NAME}",
      "id": "${CONTAINER_ID}"
    },
    "message": "${MESSAGE}"
  }
}
EOF
)
    ;;
    
  *)
    echo "Unknown event type: $EVENT_TYPE" >&2
    exit 1
    ;;
esac

# Send webhook using curl
RESPONSE=$(curl -s -w "\n%{http_code}" \
  --max-time "${WEBHOOK_TIMEOUT}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d "${PAYLOAD}" \
  "${WEBHOOK_URL}" 2>&1)

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

# Log result (non-blocking - don't fail if webhook fails)
if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
  echo "[$(date)] Webhook sent successfully: ${EVENT_TYPE} (HTTP ${HTTP_CODE})" >> /var/log/cron.log 2>&1
else
  echo "[$(date)] Webhook failed: ${EVENT_TYPE} (HTTP ${HTTP_CODE}) - ${BODY}" >> /var/log/cron.log 2>&1
fi

exit 0

