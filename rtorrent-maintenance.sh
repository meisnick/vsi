#!/bin/bash
LOGFILE="/var/log/rtorrent-maintenance.log"
DATE=$(date '+%Y-%m-%d %H:%M:%S')

echo "=== rTorrent Maintenance: $DATE ===" >> $LOGFILE

# Find rtorrent session directory (adjust path as needed)
SESSION_DIR="/home/__USERNAME__/rtorrent/.session"

if [ -n "$SESSION_DIR" ]; then
    echo "Session directory: $SESSION_DIR" >> $LOGFILE
    echo "Session files count: $(ls -1 $SESSION_DIR/*.torrent* 2>/dev/null | wc -l)" >> $LOGFILE
    echo "Session directory size: $(du -sh $SESSION_DIR 2>/dev/null | awk '{print $1}')" >> $LOGFILE
fi

# Check for hung rtorrent processes
RTORRENT_PROCS=$(pgrep -c rtorrent)
echo "Active rtorrent processes: $RTORRENT_PROCS" >> $LOGFILE

# Check inode usage (important for many small torrent files)
echo "Inode usage:" >> $LOGFILE
df -i / >> $LOGFILE

echo "========================================" >> $LOGFILE
