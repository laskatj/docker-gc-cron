#!/bin/sh

# debug-gc.sh - Debug script to help identify why images aren't being cleaned up
# Usage: docker exec docker-gc sh /debug-gc.sh [image_name_or_id]

echo "=== Docker GC Debug Tool ==="
echo ""

# Source environment if available
if [ -f /etc/environment.docker-gc ]; then
  set -a
  . /etc/environment.docker-gc
  set +a
fi

# Check if specific image was requested
IMAGE_TO_CHECK="$1"

echo "1. Checking environment variables..."
echo "   GRACE_PERIOD_SECONDS: ${GRACE_PERIOD_SECONDS:-3600} (default)"
echo "   FORCE_IMAGE_REMOVAL: ${FORCE_IMAGE_REMOVAL:-0} (default)"
echo "   MINIMUM_IMAGES_TO_SAVE: ${MINIMUM_IMAGES_TO_SAVE:-not set}"
echo "   DRY_RUN: ${DRY_RUN:-0} (default)"
echo ""

echo "2. Checking exclude file..."
EXCLUDE_FILE="/etc/docker-gc-exclude"
if [ -f "$EXCLUDE_FILE" ]; then
  echo "   Exclude file exists: $EXCLUDE_FILE"
  echo "   Contents:"
  cat "$EXCLUDE_FILE" | sed 's/^/      /'
else
  echo "   Exclude file not found (this is OK)"
fi
echo ""

echo "3. Listing all images..."
docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.CreatedAt}}\t{{.Size}}" 2>/dev/null || echo "   Error: Could not list images (check DOCKER_HOST)"
echo ""

if [ -n "$IMAGE_TO_CHECK" ]; then
  echo "4. Checking specific image: $IMAGE_TO_CHECK"
  
  # Try to find the image
  IMAGE_INFO=$(docker images --format "{{.Repository}}:{{.Tag}}\t{{.ID}}" 2>/dev/null | grep -i "$IMAGE_TO_CHECK" | head -1)
  
  if [ -z "$IMAGE_INFO" ]; then
    echo "   Image not found. Trying by ID..."
    IMAGE_INFO=$(docker images --format "{{.Repository}}:{{.Tag}}\t{{.ID}}" 2>/dev/null | grep "$IMAGE_TO_CHECK" | head -1)
  fi
  
  if [ -n "$IMAGE_INFO" ]; then
    IMAGE_NAME=$(echo "$IMAGE_INFO" | cut -f1)
    IMAGE_ID=$(echo "$IMAGE_INFO" | cut -f2)
    
    echo "   Found: $IMAGE_NAME (ID: $IMAGE_ID)"
    echo ""
    
    echo "   a) Checking if image is in exclude file..."
    if grep -q "$IMAGE_NAME" "$EXCLUDE_FILE" 2>/dev/null || grep -q "$IMAGE_ID" "$EXCLUDE_FILE" 2>/dev/null; then
      echo "      ⚠️  IMAGE IS EXCLUDED - This is why it's not being deleted!"
    else
      echo "      ✓ Not in exclude file"
    fi
    echo ""
    
    echo "   b) Checking if image is used by containers..."
    CONTAINERS=$(docker ps -a --filter "ancestor=$IMAGE_NAME" --format "{{.ID}}\t{{.Status}}\t{{.Names}}" 2>/dev/null)
    if [ -n "$CONTAINERS" ]; then
      echo "      ⚠️  IMAGE IS IN USE BY CONTAINERS:"
      echo "$CONTAINERS" | sed 's/^/         /'
      echo "      This prevents deletion!"
    else
      echo "      ✓ Not used by any containers"
    fi
    echo ""
    
    echo "   c) Checking image age vs GRACE_PERIOD_SECONDS..."
    IMAGE_CREATED=$(docker inspect --format '{{.Created}}' "$IMAGE_ID" 2>/dev/null)
    if [ -n "$IMAGE_CREATED" ]; then
      # Alpine Linux date command (GNU date compatible)
      IMAGE_EPOCH=$(date -d "$IMAGE_CREATED" +%s 2>/dev/null || echo "0")
      NOW_EPOCH=$(date +%s)
      
      if [ "$IMAGE_EPOCH" != "0" ] && [ "$NOW_EPOCH" -gt "$IMAGE_EPOCH" ]; then
        AGE_SECONDS=$((NOW_EPOCH - IMAGE_EPOCH))
        GRACE_PERIOD=${GRACE_PERIOD_SECONDS:-3600}
        
        echo "      Image created: $IMAGE_CREATED"
        echo "      Image age: $AGE_SECONDS seconds ($(($AGE_SECONDS / 3600)) hours)"
        echo "      Grace period: $GRACE_PERIOD seconds ($(($GRACE_PERIOD / 3600)) hours)"
        
        if [ "$AGE_SECONDS" -lt "$GRACE_PERIOD" ]; then
          echo "      ⚠️  IMAGE IS TOO NEW - Will not be deleted until grace period expires"
        else
          echo "      ✓ Image is old enough to be deleted"
        fi
      else
        echo "      Image created: $IMAGE_CREATED"
        echo "      Could not calculate age (date parsing issue)"
      fi
    else
      echo "      Could not determine image creation time"
    fi
    echo ""
    
    echo "   d) Checking if image has multiple tags..."
    TAG_COUNT=$(docker images --format "{{.ID}}" 2>/dev/null | grep -c "^${IMAGE_ID}$" || echo "0")
    if [ "$TAG_COUNT" -gt 1 ]; then
      echo "      ⚠️  IMAGE HAS MULTIPLE TAGS:"
      docker images --format "   {{.Repository}}:{{.Tag}}" 2>/dev/null | grep -B1 -A1 "$IMAGE_ID" | sed 's/^/         /'
      if [ "${FORCE_IMAGE_REMOVAL:-0}" != "1" ]; then
        echo "      ⚠️  FORCE_IMAGE_REMOVAL is not set - images with multiple tags won't be deleted"
      else
        echo "      ✓ FORCE_IMAGE_REMOVAL=1, so this should be OK"
      fi
    else
      echo "      ✓ Image has single tag"
    fi
    echo ""
    
    echo "   e) Checking MINIMUM_IMAGES_TO_SAVE setting..."
    if [ -n "$MINIMUM_IMAGES_TO_SAVE" ] && [ "$MINIMUM_IMAGES_TO_SAVE" -gt 0 ]; then
      REPO_NAME=$(echo "$IMAGE_NAME" | cut -d: -f1)
      REPO_IMAGE_COUNT=$(docker images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -c "^${REPO_NAME}:" || echo "0")
      echo "      Repository: $REPO_NAME"
      echo "      Images in repository: $REPO_IMAGE_COUNT"
      echo "      MINIMUM_IMAGES_TO_SAVE: $MINIMUM_IMAGES_TO_SAVE"
      
      if [ "$REPO_IMAGE_COUNT" -le "$MINIMUM_IMAGES_TO_SAVE" ]; then
        echo "      ⚠️  TOO FEW IMAGES IN REPO - All images are being preserved"
      else
        echo "      ✓ Repository has enough images, oldest can be deleted"
      fi
    else
      echo "      ✓ MINIMUM_IMAGES_TO_SAVE not set"
    fi
    echo ""
  else
    echo "   Image not found: $IMAGE_TO_CHECK"
  fi
else
  echo "4. Running dry-run to see what docker-gc would delete..."
  echo "   (Set DRY_RUN=1 and run docker-gc manually)"
  echo ""
fi

echo "5. Checking for dangling/unused images..."
DANGLING=$(docker images -f "dangling=true" --format "{{.ID}}" 2>/dev/null | wc -l)
echo "   Dangling images: $DANGLING"
echo ""

echo "6. Checking for stopped containers that might reference images..."
STOPPED=$(docker ps -a --filter "status=exited" --format "{{.ID}}\t{{.Image}}\t{{.Names}}" 2>/dev/null | wc -l)
echo "   Stopped containers: $STOPPED"
if [ "$STOPPED" -gt 0 ]; then
  echo "   (Stopped containers prevent their images from being deleted)"
  echo "   Recent stopped containers:"
  docker ps -a --filter "status=exited" --format "   {{.ID}}\t{{.Image}}\t{{.Names}}" 2>/dev/null | head -5
fi
echo ""

echo "7. To test what docker-gc would do, run:"
echo "   docker exec docker-gc sh -c 'DRY_RUN=1 /usr/bin/docker-gc'"
echo ""

echo "=== Debug Complete ==="

