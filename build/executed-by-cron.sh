#!/bin/sh

# Source environment variables that might not be available in cron context
if [ -f /etc/environment.docker-gc ]; then
  set -a
  . /etc/environment.docker-gc
  set +a
fi

# Send webhook notification that GC has started
/send-webhook.sh "gc_started" >> /var/log/cron.log 2>&1

echo "[$(date)] Docker GC starting." >> /var/log/cron.log 2>&1

# Initialize summary tracking (use temp files since while loop runs in subshell)
SUMMARY_DIR=$(mktemp -d)
IMAGES_FILE="${SUMMARY_DIR}/images"
CONTAINERS_FILE="${SUMMARY_DIR}/containers"
IMAGE_LOOKUP_FILE="${SUMMARY_DIR}/image_lookup"
CONTAINER_LOOKUP_FILE="${SUMMARY_DIR}/container_lookup"
touch "$IMAGES_FILE"
touch "$CONTAINERS_FILE"

# Capture image and container information BEFORE deletion for lookup
# This allows us to get names even if docker-gc output doesn't include them
echo "[$(date)] Capturing pre-deletion image and container list..." >> /var/log/cron.log 2>&1

# Build image lookup: ID -> name:tag
docker images --format "{{.ID}}|{{.Repository}}:{{.Tag}}" 2>/dev/null > "$IMAGE_LOOKUP_FILE" || touch "$IMAGE_LOOKUP_FILE"

# Build container lookup: ID -> name
docker ps -a --format "{{.ID}}|{{.Names}}" 2>/dev/null > "$CONTAINER_LOOKUP_FILE" || touch "$CONTAINER_LOOKUP_FILE"

# Protect images associated with stopped containers from deletion
# Get all stopped containers and their image IDs, then add them to exclude file
echo "[$(date)] Protecting images associated with stopped containers..." >> /var/log/cron.log 2>&1
STOPPED_CONTAINERS_TEMP=$(mktemp)
docker ps -a --filter "status=exited" --format "{{.ID}}|{{.Image}}" 2>/dev/null > "$STOPPED_CONTAINERS_TEMP" || touch "$STOPPED_CONTAINERS_TEMP"

EXCLUDE_FILE="/etc/docker-gc-exclude"
EXCLUDE_BACKUP="${EXCLUDE_FILE}.backup.$$"
# Create backup of original exclude file
cp "$EXCLUDE_FILE" "$EXCLUDE_BACKUP" 2>/dev/null || touch "$EXCLUDE_BACKUP"

# Read existing excludes into a set (using a temp file for tracking)
EXISTING_EXCLUDES=$(mktemp)
grep -v '^#' "$EXCLUDE_FILE" 2>/dev/null | grep -v '^$' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' > "$EXISTING_EXCLUDES" || touch "$EXISTING_EXCLUDES"

# Process stopped containers and add their images to exclude file
ADDED_COUNT=0
while IFS='|' read -r CONTAINER_ID IMAGE_REF; do
  [ -z "$CONTAINER_ID" ] && continue
  
  # Get the image ID from the image reference (could be name:tag or ID)
  IMAGE_ID=""
  # If it's already an image ID (starts with sha256: or is a short hash), use it
  if echo "$IMAGE_REF" | grep -qE '^(sha256:)?[a-f0-9]{12,64}$'; then
    IMAGE_ID="$IMAGE_REF"
  else
    # Otherwise, get the image ID from the image name:tag
    IMAGE_ID=$(docker inspect --format '{{.Id}}' "$IMAGE_REF" 2>/dev/null || echo "")
    if [ -z "$IMAGE_ID" ]; then
      # Try to get it from docker images
      IMAGE_ID=$(docker images --format "{{.ID}}" --filter "reference=${IMAGE_REF}" 2>/dev/null | head -1 || echo "")
    fi
  fi
  
  if [ -n "$IMAGE_ID" ]; then
    # Normalize image ID (remove sha256: prefix, get short version)
    NORMALIZED_ID=$(echo "$IMAGE_ID" | sed 's/sha256://')
    SHORT_ID=$(echo "$NORMALIZED_ID" | cut -c1-12)
    
    # Check if this image ID (or its short version) is already in excludes
    if ! grep -qE "^(${IMAGE_ID}|${NORMALIZED_ID}|${SHORT_ID})$" "$EXISTING_EXCLUDES" 2>/dev/null; then
      # Add both short and full ID to be safe (docker-gc might use either)
      echo "$SHORT_ID" >> "$EXCLUDE_FILE"
      echo "[$(date)] Added image ID ${SHORT_ID} (from stopped container ${CONTAINER_ID}) to exclude file" >> /var/log/cron.log 2>&1
      echo "$SHORT_ID" >> "$EXISTING_EXCLUDES"  # Track what we added
      ADDED_COUNT=$((ADDED_COUNT + 1))
    fi
  fi
done < "$STOPPED_CONTAINERS_TEMP"

if [ "$ADDED_COUNT" -gt 0 ]; then
  echo "[$(date)] Protected ${ADDED_COUNT} image(s) associated with stopped containers" >> /var/log/cron.log 2>&1
fi

# Clean up temp files
rm -f "$STOPPED_CONTAINERS_TEMP" "$EXISTING_EXCLUDES"

# Exclude all containers from deletion - only clean up images
# This prevents docker-gc from deleting any containers (running or stopped)
export EXCLUDE_CONTAINERS='*'
echo "[$(date)] Container deletion disabled (EXCLUDE_CONTAINERS=*). Only images will be cleaned." >> /var/log/cron.log 2>&1

# Capture docker-gc output to parse for deletions
GC_OUTPUT=$(/usr/bin/docker-gc 2>&1)
GC_EXIT_CODE=$?

# Log the output
echo "$GC_OUTPUT" >> /var/log/cron.log 2>&1

# Parse docker-gc output for deleted images and containers
# docker-gc outputs various formats, we try to catch common patterns:
# - "[timestamp] [INFO] : Removing image <id> [<name>:<tag>]"
# - "Removing image <id> (<name>:<tag>)"
# - "Removing container <id> (<name>)"
# - "Deleted: <id>"
# - "Deleting image <name>:<tag>"
# - "Deleting container <name>"

echo "$GC_OUTPUT" | while IFS= read -r line; do
  # Skip empty lines
  [ -z "$line" ] && continue
  
  # Check for image deletion patterns (case-insensitive)
  if echo "$line" | grep -qiE "(removing|deleted|deleting).*image"; then
    IMAGE_ID=""
    IMAGE_NAME=""
    IMAGE_TAG=""
    
    # Pattern 1: Extract image ID (handles sha256: prefix and full hash)
    # Matches: "Removing image sha256:abc123..." or "Removing image abc123..."
    IMAGE_ID=$(echo "$line" | sed -nE 's/.*[Rr]emoving [Ii]mage[[:space:]]+(sha256:)?([a-f0-9]{12,64}).*/\1\2/p' | head -1)
    
    # Pattern 2: "Deleted: <id>" or "Deleted image: <id>"
    if [ -z "$IMAGE_ID" ]; then
      IMAGE_ID=$(echo "$line" | sed -nE 's/.*[Dd]eleted[[:space:]]*:?[[:space:]]+(sha256:)?([a-f0-9]{12,64}).*/\1\2/p' | head -1)
    fi
    
    # Extract image name and tag from square brackets: [<name>:<tag>] or [<name>]
    # Look for brackets that appear after "Removing image" or image ID (to avoid matching timestamp brackets)
    IMAGE_INFO=$(echo "$line" | sed -nE 's/.*[Rr]emoving [Ii]mage[^[]*\[([^\]]+)\].*/\1/p' | head -1)
    # Fallback: try to get the last bracket pair (usually the image name)
    if [ -z "$IMAGE_INFO" ]; then
      IMAGE_INFO=$(echo "$line" | sed -nE 's/.*\[([^\]]+)\]$/\1/p' | head -1)
    fi
    if [ -n "$IMAGE_INFO" ]; then
      # Check if it contains a colon (name:tag format)
      if echo "$IMAGE_INFO" | grep -q ":"; then
        IMAGE_NAME=$(echo "$IMAGE_INFO" | cut -d: -f1)
        IMAGE_TAG=$(echo "$IMAGE_INFO" | cut -d: -f2-)
      else
        IMAGE_NAME="$IMAGE_INFO"
        IMAGE_TAG=""
      fi
    fi
    
    # Pattern 3: Extract from parentheses: (<name>:<tag>) or (<name>) - fallback
    if [ -z "$IMAGE_INFO" ]; then
      IMAGE_INFO=$(echo "$line" | sed -nE 's/.*\(([^)]+)\).*/\1/p' | head -1)
      if [ -n "$IMAGE_INFO" ]; then
        if echo "$IMAGE_INFO" | grep -q ":"; then
          IMAGE_NAME=$(echo "$IMAGE_INFO" | cut -d: -f1)
          IMAGE_TAG=$(echo "$IMAGE_INFO" | cut -d: -f2-)
        else
          IMAGE_NAME="$IMAGE_INFO"
          IMAGE_TAG=""
        fi
      fi
    fi
    
    # Pattern 4: "Deleting image <name>:<tag>" (without ID)
    if [ -z "$IMAGE_NAME" ] && [ -z "$IMAGE_ID" ]; then
      IMAGE_FULL=$(echo "$line" | sed -nE 's/.*[Dd]eleting [Ii]mage[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)
      if [ -n "$IMAGE_FULL" ]; then
        if echo "$IMAGE_FULL" | grep -q ":"; then
          IMAGE_NAME=$(echo "$IMAGE_FULL" | cut -d: -f1)
          IMAGE_TAG=$(echo "$IMAGE_FULL" | cut -d: -f2-)
        else
          IMAGE_NAME="$IMAGE_FULL"
          IMAGE_TAG=""
        fi
      fi
    fi
    
    # Track deleted image in summary (suppress individual webhooks)
    if [ -n "$IMAGE_ID" ] || [ -n "$IMAGE_NAME" ]; then
      # If we have an ID but no name, look it up from our pre-deletion snapshot
      if [ -n "$IMAGE_ID" ] && ([ -z "$IMAGE_NAME" ] || [ "$IMAGE_NAME" = "unknown" ]); then
        # Normalize ID (remove sha256: prefix, use short or full)
        NORMALIZED_ID=$(echo "$IMAGE_ID" | sed 's/sha256://')
        SHORT_ID=$(echo "$NORMALIZED_ID" | cut -c1-12)
        
        # Look up in our pre-deletion image list
        LOOKUP_RESULT=$(grep -E "^(${IMAGE_ID}|${NORMALIZED_ID}|${SHORT_ID})\|" "$IMAGE_LOOKUP_FILE" 2>/dev/null | head -1)
        
        if [ -n "$LOOKUP_RESULT" ]; then
          # Extract name:tag from lookup (format: ID|name:tag)
          IMAGE_INFO=$(echo "$LOOKUP_RESULT" | cut -d'|' -f2-)
          if [ -n "$IMAGE_INFO" ] && [ "$IMAGE_INFO" != "<none>:<none>" ]; then
            if echo "$IMAGE_INFO" | grep -q ":"; then
              IMAGE_NAME=$(echo "$IMAGE_INFO" | cut -d: -f1)
              IMAGE_TAG=$(echo "$IMAGE_INFO" | cut -d: -f2-)
            else
              IMAGE_NAME="$IMAGE_INFO"
              IMAGE_TAG=""
            fi
          fi
        fi
        
        # If still no name, it's likely a dangling/untagged image
        if [ -z "$IMAGE_NAME" ] || [ "$IMAGE_NAME" = "unknown" ]; then
          IMAGE_NAME="<none>"
          IMAGE_TAG="<none>"
        fi
      fi
      
      # Format: name:tag|id (or just name|id if no tag)
      IMAGE_FULL="${IMAGE_NAME:-unknown}${IMAGE_TAG:+:${IMAGE_TAG}}"
      if [ -n "$IMAGE_ID" ]; then
        echo "${IMAGE_FULL}|${IMAGE_ID}" >> "$IMAGES_FILE"
      else
        echo "${IMAGE_FULL}" >> "$IMAGES_FILE"
      fi
    fi
  fi
  
  # Check for container deletion patterns (case-insensitive)
  if echo "$line" | grep -qiE "(removing|deleted|deleting).*container"; then
    CONTAINER_ID=""
    CONTAINER_NAME=""
    
    # Pattern 1: "Removing container <id> (<name>)" or "Removing container <id>" or "[timestamp] [INFO] : Removing container <id> [<name>]"
    CONTAINER_ID=$(echo "$line" | sed -nE 's/.*[Rr]emoving [Cc]ontainer[[:space:]]+([a-f0-9]{12,64}).*/\1/p' | head -1)
    
    # Pattern 2: "Deleted: <id>" or "Deleted container: <id>"
    if [ -z "$CONTAINER_ID" ]; then
      CONTAINER_ID=$(echo "$line" | sed -nE 's/.*[Dd]eleted[[:space:]]*:?[[:space:]]+([a-f0-9]{12,64}).*/\1/p' | head -1)
    fi
    
    # Extract container name from square brackets: [<name>]
    # Look for brackets that appear after "Removing container" or container ID
    CONTAINER_NAME=$(echo "$line" | sed -nE 's/.*[Rr]emoving [Cc]ontainer[^[]*\[([^\]]+)\].*/\1/p' | head -1)
    # Fallback: try to get the last bracket pair (usually the container name)
    if [ -z "$CONTAINER_NAME" ]; then
      CONTAINER_NAME=$(echo "$line" | sed -nE 's/.*\[([^\]]+)\]$/\1/p' | head -1)
    fi
    
    # Fallback: Extract container name from parentheses: (<name>)
    if [ -z "$CONTAINER_NAME" ]; then
      CONTAINER_NAME=$(echo "$line" | sed -nE 's/.*\(([^)]+)\).*/\1/p' | head -1)
    fi
    
    # Pattern 3: "Deleting container <name>" (without ID)
    if [ -z "$CONTAINER_NAME" ] && [ -z "$CONTAINER_ID" ]; then
      CONTAINER_NAME=$(echo "$line" | sed -nE 's/.*[Dd]eleting [Cc]ontainer[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)
    fi
    
    # Track deleted container in summary (suppress individual webhooks)
    if [ -n "$CONTAINER_ID" ] || [ -n "$CONTAINER_NAME" ]; then
      # If we have an ID but no name, look it up from our pre-deletion snapshot
      if [ -n "$CONTAINER_ID" ] && ([ -z "$CONTAINER_NAME" ] || [ "$CONTAINER_NAME" = "unknown" ]); then
        # Look up in our pre-deletion container list
        LOOKUP_RESULT=$(grep "^${CONTAINER_ID}|" "$CONTAINER_LOOKUP_FILE" 2>/dev/null | head -1)
        
        if [ -n "$LOOKUP_RESULT" ]; then
          # Extract name from lookup (format: ID|name)
          CONTAINER_NAME=$(echo "$LOOKUP_RESULT" | cut -d'|' -f2-)
        fi
      fi
      
      # Format: name|id (or just name if no id)
      CONTAINER_FULL="${CONTAINER_NAME:-unknown}"
      if [ -n "$CONTAINER_ID" ]; then
        echo "${CONTAINER_FULL}|${CONTAINER_ID}" >> "$CONTAINERS_FILE"
      else
        echo "${CONTAINER_FULL}" >> "$CONTAINERS_FILE"
      fi
    fi
  fi
done

# Handle volume cleanup
if [ "$CLEAN_UP_VOLUMES" == "1" ]; then
  if [ "$(docker volume ls -qf dangling=true 2>/dev/null | wc -l)" -gt 0 ]; then
    echo "Cleaning up dangling volumes." >> /var/log/cron.log 2>&1
    docker volume rm $(docker volume ls -qf dangling=true) >> /var/log/cron.log 2>&1
  else
    echo "No dangling volumes found." >> /var/log/cron.log 2>&1
  fi
fi

# Read summary data and build JSON arrays (limit to 50 items each to avoid huge payloads)
IMAGE_COUNT=$(wc -l < "$IMAGES_FILE" 2>/dev/null | tr -d ' ' || echo "0")
CONTAINER_COUNT=$(wc -l < "$CONTAINERS_FILE" 2>/dev/null | tr -d ' ' || echo "0")

# Build JSON arrays from files (limit to first 50)
# Use a function to build JSON arrays to avoid subshell variable issues
build_json_array() {
  local file="$1"
  local type="$2"  # "image" or "container"
  
  # Check if file exists and has content
  if [ ! -f "$file" ] || [ ! -s "$file" ]; then
    echo "[]"
    return
  fi
  
  local json="["
  local first=true
  local line_num=0
  
  while IFS= read -r line && [ "$line_num" -lt 50 ]; do
    # Skip empty lines
    [ -z "$line" ] && continue
    
    if [ "$first" = "true" ]; then
      first=false
    else
      json="${json},"
    fi
    
    if [ "$type" = "image" ]; then
      # Parse name:tag|id format (or just name|id or name:tag or just name)
      if echo "$line" | grep -q "|"; then
        name_tag=$(echo "$line" | cut -d'|' -f1)
        id=$(echo "$line" | cut -d'|' -f2-)
      else
        name_tag="$line"
        id=""
      fi
      
      # Parse name:tag or just name
      if echo "$name_tag" | grep -q ":"; then
        name=$(echo "$name_tag" | cut -d: -f1)
        tag=$(echo "$name_tag" | cut -d: -f2-)
      else
        name="$name_tag"
        tag=""
      fi
      
      # Escape for JSON (handle newlines, tabs, etc.)
      name=$(printf '%s' "$name" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed 's/\n/\\n/g' | sed 's/\r/\\r/g' | sed 's/\t/\\t/g')
      tag=$(printf '%s' "$tag" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed 's/\n/\\n/g' | sed 's/\r/\\r/g' | sed 's/\t/\\t/g')
      id=$(printf '%s' "$id" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed 's/\n/\\n/g' | sed 's/\r/\\r/g' | sed 's/\t/\\t/g')
      
      json="${json}{\"name\":\"${name}\",\"tag\":\"${tag}\",\"id\":\"${id}\"}"
    else
      # Parse name|id format (or just name)
      if echo "$line" | grep -q "|"; then
        name=$(echo "$line" | cut -d'|' -f1)
        id=$(echo "$line" | cut -d'|' -f2-)
      else
        name="$line"
        id=""
      fi
      
      # Escape for JSON
      name=$(printf '%s' "$name" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed 's/\n/\\n/g' | sed 's/\r/\\r/g' | sed 's/\t/\\t/g')
      id=$(printf '%s' "$id" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed 's/\n/\\n/g' | sed 's/\r/\\r/g' | sed 's/\t/\\t/g')
      
      json="${json}{\"name\":\"${name}\",\"id\":\"${id}\"}"
    fi
    
    line_num=$((line_num + 1))
  done < "$file"
  
  json="${json}]"
  echo "$json"
}

IMAGE_JSON_ARRAY=$(build_json_array "$IMAGES_FILE" "image")
CONTAINER_JSON_ARRAY=$(build_json_array "$CONTAINERS_FILE" "container")

# Build title based on counts
if [ "$IMAGE_COUNT" -eq 0 ] && [ "$CONTAINER_COUNT" -eq 0 ]; then
  TITLE="No actions taken"
elif [ "$IMAGE_COUNT" -gt 0 ] && [ "$CONTAINER_COUNT" -gt 0 ]; then
  IMAGE_PLURAL=""
  [ "$IMAGE_COUNT" -ne 1 ] && IMAGE_PLURAL="s"
  CONTAINER_PLURAL=""
  [ "$CONTAINER_COUNT" -ne 1 ] && CONTAINER_PLURAL="s"
  TITLE="${IMAGE_COUNT} image${IMAGE_PLURAL} and ${CONTAINER_COUNT} container${CONTAINER_PLURAL} deleted"
elif [ "$IMAGE_COUNT" -gt 0 ]; then
  IMAGE_PLURAL=""
  [ "$IMAGE_COUNT" -ne 1 ] && IMAGE_PLURAL="s"
  TITLE="${IMAGE_COUNT} image${IMAGE_PLURAL} deleted"
else
  CONTAINER_PLURAL=""
  [ "$CONTAINER_COUNT" -ne 1 ] && CONTAINER_PLURAL="s"
  TITLE="${CONTAINER_COUNT} container${CONTAINER_PLURAL} deleted"
fi

# Build summary message
SUMMARY_MSG="Docker garbage collection completed successfully"
if [ "$IMAGE_COUNT" -gt 0 ] || [ "$CONTAINER_COUNT" -gt 0 ]; then
  SUMMARY_MSG="${SUMMARY_MSG}. Deleted ${IMAGE_COUNT} image(s) and ${CONTAINER_COUNT} container(s)"
else
  SUMMARY_MSG="${SUMMARY_MSG}. No images or containers were deleted"
fi

# Send appropriate completion webhook with summary
if [ "$GC_EXIT_CODE" -eq 0 ]; then
  echo "[$(date)] Docker GC has completed. ${TITLE}" >> /var/log/cron.log 2>&1
  /send-webhook.sh "gc_finished" "${TITLE}" "${IMAGE_COUNT}" "${CONTAINER_COUNT}" "${IMAGE_JSON_ARRAY}" "${CONTAINER_JSON_ARRAY}" "${SUMMARY_MSG}" >> /var/log/cron.log 2>&1
else
  ERROR_MSG="Docker garbage collection failed with exit code ${GC_EXIT_CODE}"
  echo "[$(date)] ${ERROR_MSG}" >> /var/log/cron.log 2>&1
  /send-webhook.sh "gc_failed" "" "" "" "" "" "${ERROR_MSG}" >> /var/log/cron.log 2>&1
fi

# Clean up temp files
rm -rf "$SUMMARY_DIR"

exit $GC_EXIT_CODE
