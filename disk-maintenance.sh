#!/bin/bash
LOG_FILE="/var/log/disk-maintenance.log"
{
    echo "=== Disk Maintenance: $(date '+%Y-%m-%d %H:%M:%S') ==="
    echo "Disk Usage:"
    df -h / | grep -v Filesystem
    df -i / | grep -v Filesystem
    echo "Recent filesystem errors:"
    ERROR_COUNT=$(dmesg | grep -iE "ext4.*error|I/O error|filesystem.*corrupt|remount.*read-only" | grep -v "EXT4-fs.*mounted" | grep -v "Quota mode" | grep -v "RAS:" | grep -v "GPT:" | wc -l)
    if [ "$ERROR_COUNT" -eq 0 ]; then
        echo "✓ No filesystem errors detected"
    else
        dmesg | grep -iE "ext4.*error|I/O error|filesystem.*corrupt|remount.*read-only" | grep -v "EXT4-fs.*mounted" | grep -v "Quota mode" | grep -v "RAS:" | grep -v "GPT:" | tail -10
        echo "⚠ WARNING: $ERROR_COUNT filesystem errors found"
    fi
    echo "LVM Status:"
    lvs
    vgs
    echo "Mount status:"
    mount | grep 'mapper.*ext4'
    echo "Memory:"
    free -h
    echo "========================================"
} >> "$LOG_FILE" 2>&1
[ -f "$LOG_FILE" ] && [ $(wc -l < "$LOG_FILE") -gt 1000 ] && tail -n 1000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
