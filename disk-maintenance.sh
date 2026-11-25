#!/bin/bash
LOG_FILE="/var/log/disk-maintenance.log"
{
    echo "=== Disk Maintenance: $(date '+%Y-%m-%d %H:%M:%S') ==="
    echo "Disk Usage:"
    df -h / | grep -v Filesystem
    df -i / | grep -v Filesystem
    echo "Recent filesystem errors:"
    ERROR_COUNT=$(dmesg | grep -iE "ext4.*error|xfs.*error|btrfs.*error|I/O error|filesystem.*corrupt|remount.*read-only" | grep -v "EXT4-fs.*mounted" | grep -v "Quota mode" | grep -v "RAS:" | grep -v "GPT:" | wc -l)
    if [ "$ERROR_COUNT" -eq 0 ]; then
        echo "✓ No filesystem errors detected"
    else
        dmesg | grep -iE "ext4.*error|xfs.*error|btrfs.*error|I/O error|filesystem.*corrupt|remount.*read-only" | grep -v "EXT4-fs.*mounted" | grep -v "Quota mode" | grep -v "RAS:" | grep -v "GPT:" | tail -10
        echo "⚠ WARNING: $ERROR_COUNT filesystem errors found"
    fi
    # LVM is optional — only report it when volume groups actually exist
    if command -v vgs >/dev/null 2>&1 && [ -n "$(vgs --noheadings 2>/dev/null)" ]; then
        echo "LVM Status:"
        lvs
        vgs
    else
        echo "LVM: not in use"
    fi
    echo "Mount status:"
    findmnt -rn -t ext4,xfs,btrfs -o TARGET,SOURCE,FSTYPE,OPTIONS
    RO_MOUNTS=$(findmnt -rn -t ext4,xfs,btrfs -O ro -o TARGET)
    if [ -n "$RO_MOUNTS" ]; then
        echo "⚠ WARNING: read-only filesystem(s): $RO_MOUNTS"
    fi
    echo "Memory:"
    free -h
    echo "========================================"
} >> "$LOG_FILE" 2>&1
[ -f "$LOG_FILE" ] && [ $(wc -l < "$LOG_FILE") -gt 1000 ] && tail -n 1000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
