#!/bin/bash
# Monitor PHP-FPM restarts and log potential issues

LOG_FILE="/var/log/php-fpm-monitor.log"
PHP_LOG="/var/log/php8.3-fpm.log"

# Count restarts in the last hour
LAST_HOUR_RESTARTS=$(grep "fpm is running" "$PHP_LOG" 2>/dev/null | grep -c "$(date '+%d-%b-%Y %H')")

if [ "$LAST_HOUR_RESTARTS" -gt 5 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: PHP-FPM restarted $LAST_HOUR_RESTARTS times in the last hour" >> "$LOG_FILE"
    
    # Check for common issues
    echo "Checking for errors..." >> "$LOG_FILE"
    grep -E "WARNING|ERROR" "$PHP_LOG" | tail -5 >> "$LOG_FILE"
    
    # Check memory
    echo "Memory status:" >> "$LOG_FILE"
    free -h >> "$LOG_FILE"
    echo "---" >> "$LOG_FILE"
fi
