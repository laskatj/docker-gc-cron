#!/bin/bash

DEFAULT_CRON="0 0 * * *"

if [ "$CRON" ]; then
   echo "Using user-defined CRON variable: $CRON"
else
   echo "CRON variable undefined. Using default of \"$DEFAULT_CRON\""
   CRON="$DEFAULT_CRON"
fi

GC_ARGS=""

if [ "$CLEAN_UP_VOLUMES" ]; then
   GC_ARGS="$GC_ARGS CLEAN_UP_VOLUMES=$CLEAN_UP_VOLUMES"
fi

if [ "$DRY_RUN" ]; then
   GC_ARGS="$GC_ARGS DRY_RUN=$DRY_RUN"
fi

if [ "$EXCLUDE_VOLUMES_IDS_FILE" ]; then
   GC_ARGS="$GC_ARGS EXCLUDE_VOLUMES_IDS_FILE=$EXCLUDE_VOLUMES_IDS_FILE"
fi

if [ "$FORCE_CONTAINER_REMOVAL" ]; then
   GC_ARGS="$GC_ARGS FORCE_CONTAINER_REMOVAL=$FORCE_CONTAINER_REMOVAL"
fi

if [ "$FORCE_IMAGE_REMOVAL" ]; then
   GC_ARGS="$GC_ARGS FORCE_IMAGE_REMOVAL=$FORCE_IMAGE_REMOVAL"
fi

if [ "$GRACE_PERIOD_SECONDS" ]; then
   GC_ARGS="$GC_ARGS GRACE_PERIOD_SECONDS=$GRACE_PERIOD_SECONDS"
fi

if [ "$MINIMUM_IMAGES_TO_SAVE" ]; then
   GC_ARGS="$GC_ARGS MINIMUM_IMAGES_TO_SAVE=$MINIMUM_IMAGES_TO_SAVE"
fi

if [ "$REMOVE_VOLUMES" ]; then
   GC_ARGS="$GC_ARGS REMOVE_VOLUMES=$REMOVE_VOLUMES"
fi

if [ "$VOLUME_DELETE_ONLY_DRIVER" ]; then
   GC_ARGS="$GC_ARGS VOLUME_DELETE_ONLY_DRIVER=$VOLUME_DELETE_ONLY_DRIVER"
fi

# Also pass CLEAN_UP_VOLUMES to executed-by-cron.sh if set
if [ "$CLEAN_UP_VOLUMES" ]; then
   GC_ARGS="$GC_ARGS CLEAN_UP_VOLUMES=$CLEAN_UP_VOLUMES"
fi

# Note: WEBHOOK_URL and WEBHOOK_TIMEOUT are read from environment by send-webhook.sh
# They should be available since they're set as container environment variables
# If cron doesn't inherit them, we can add them here, but typically they should be available

echo -e "$CRON" "$GC_ARGS sh /executed-by-cron.sh" '>> /var/log/cron.log 2>&1'"\n" > crontab.tmp
