#!/bin/bash
# System usage alerts for the Vanilla Seedbox (run from /etc/cron.d/vsi-maintenance)
#   system-alerts.sh usage  - log root disk usage >85% and inode usage >80%
#   system-alerts.sh oom    - log kernel OOM-killer events from the last month

DISK_THRESHOLD=85
INODE_THRESHOLD=80

case "$1" in
    usage)
        DISK_PCT=$(df --output=pcent / | tail -n1 | tr -dc '0-9')
        if [ "${DISK_PCT:-0}" -gt "$DISK_THRESHOLD" ]; then
            echo "$(date): Root disk usage: ${DISK_PCT}%" >> /var/log/disk-alerts.log
        fi

        INODE_PCT=$(df --output=ipcent / | tail -n1 | tr -dc '0-9')
        if [ "${INODE_PCT:-0}" -gt "$INODE_THRESHOLD" ]; then
            echo "$(date): Inode usage: ${INODE_PCT}%" >> /var/log/inode-alerts.log
        fi
        ;;
    oom)
        # Only the last month of kernel messages, so monthly runs don't re-log old events
        EVENTS=$(journalctl -k --since "1 month ago" --no-pager 2>/dev/null | grep -iE "out of memory|killed process")
        if [ -n "$EVENTS" ]; then
            {
                echo "=== OOM events logged $(date) ==="
                echo "$EVENTS"
            } >> /var/log/oom-events.log
        fi
        ;;
    *)
        echo "Usage: $0 {usage|oom}" >&2
        exit 1
        ;;
esac
