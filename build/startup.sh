#!/bin/sh

# startup.sh - Handles container startup, optionally running GC immediately

# Generate crontab and start cron
/generate-crontab.sh > /var/log/cron.log 2>&1
crontab crontab.tmp

# Save environment variables for cron context
printenv | grep -E "^(WEBHOOK_|DOCKER_HOST|TZ)=" > /etc/environment.docker-gc

# Start cron daemon
/usr/sbin/crond

# If RUN_ON_STARTUP is set to 1, run garbage collection immediately
if [ "$RUN_ON_STARTUP" = "1" ]; then
  echo "[$(date)] RUN_ON_STARTUP=1 detected. Running garbage collection on startup..." >> /var/log/cron.log 2>&1
  sh /executed-by-cron.sh >> /var/log/cron.log 2>&1
  echo "[$(date)] Startup garbage collection completed." >> /var/log/cron.log 2>&1
fi

# Tail the log file
tail -f /var/log/cron.log

