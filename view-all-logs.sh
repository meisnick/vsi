#!/bin/bash
# Enhanced log viewer with error highlighting (IMPROVED VERSION)

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
RESET='\033[0m'

display_log_with_errors() {
    local title="$1"
    local log_file="$2"
    local lines=${3:-20}
    local log_type="${4:-generic}"  # New parameter for log type

    echo -e "${CYAN}--- $title ---${RESET}"
    if [ -f "$log_file" ] && [ -s "$log_file" ]; then
        echo -e "Last ${lines} lines of: ${YELLOW}$log_file${RESET}"

        local ERROR_COUNT=0
        local WARN_COUNT=0

        # Different counting logic based on log type
        case "$log_type" in
            nginx_access)
                # For access logs, only count HTTP error status codes (4xx, 5xx)
                ERROR_COUNT=$(tail -n 100 "$log_file" | grep -Ec '\" [45][0-9]{2} ' 2>/dev/null || echo "0")
                WARN_COUNT=0
                ;;
            nginx_error)
                # For nginx error logs, only count actual error levels (not URLs containing "error")
                ERROR_COUNT=$(grep -Ec '\[(emerg|alert|crit|error)\]' "$log_file" 2>/dev/null || echo "0")
                WARN_COUNT=$(grep -Ec '\[warn\]' "$log_file" 2>/dev/null || echo "0")
                ;;
            php_fpm)
                # For PHP-FPM, exclude NOTICE level messages
                ERROR_COUNT=$(grep -Evc 'NOTICE:' "$log_file" | xargs -I {} grep -Eic 'ERROR:|CRITICAL:|ALERT:|EMERGENCY:' "$log_file" 2>/dev/null || echo "0")
                WARN_COUNT=$(grep -ic 'WARNING:' "$log_file" 2>/dev/null || echo "0")
                ;;
            *)
                # Generic: avoid counting "error" in URLs, paths, or normal messages
                ERROR_COUNT=$(grep -Eic '\b(error|critical|fail(ed)?)\b' "$log_file" 2>/dev/null || echo "0")
                WARN_COUNT=$(grep -Eic '\bwarning\b' "$log_file" 2>/dev/null || echo "0")
                ;;
        esac

        # Ensure they're integers
        ERROR_COUNT=${ERROR_COUNT//[^0-9]/}
        WARN_COUNT=${WARN_COUNT//[^0-9]/}
        ERROR_COUNT=${ERROR_COUNT:-0}
        WARN_COUNT=${WARN_COUNT:-0}

        if [ "$ERROR_COUNT" -gt 0 ] || [ "$WARN_COUNT" -gt 0 ]; then
            echo -e "${RED}⚠ Errors: $ERROR_COUNT, Warnings: $WARN_COUNT${RESET}"
        else
            echo -e "${GREEN}✓ No errors or warnings${RESET}"
        fi

        # Display with highlighting based on log type
        case "$log_type" in
            nginx_access)
                # Highlight HTTP error codes
                sudo tail -n "$lines" "$log_file" | \
                    GREP_COLORS='ms=01;31' grep --text --color=always -E '\" [45][0-9]{2} |$'
                ;;
            nginx_error)
                # Highlight actual error levels
                sudo tail -n "$lines" "$log_file" | \
                    GREP_COLORS='ms=01;31' grep --text --color=always -E '\[(emerg|alert|crit|error)\]|$' | \
                    GREP_COLORS='ms=01;33' grep --text --color=always -E '\[warn\]|$'
                ;;
            php_fpm)
                # Highlight non-NOTICE messages
                sudo tail -n "$lines" "$log_file" | \
                    GREP_COLORS='ms=01;31' grep --text --color=always -E 'ERROR:|CRITICAL:|ALERT:|EMERGENCY:|$' | \
                    GREP_COLORS='ms=01;33' grep --text --color=always -E 'WARNING:|$'
                ;;
            *)
                # Generic highlighting
                sudo tail -n "$lines" "$log_file" | \
                    GREP_COLORS='ms=01;31' grep --text --color=always -iE '\b(error|critical|fail(ed)?)\b|$' | \
                    GREP_COLORS='ms=01;33' grep --text --color=always -iE '\bwarning\b|$'
                ;;
        esac
    elif [ -f "$log_file" ]; then
        echo -e "${YELLOW}$log_file exists but is empty${RESET}"
    else
        echo -e "${YELLOW}$log_file not found${RESET}"
    fi
    echo ""
}

echo -e "${GREEN}=========================================="
echo "   COMPREHENSIVE LOGS OVERVIEW"
echo "==========================================${RESET}"
echo -e "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# System status
echo -e "${CYAN}=== Quick System Status ===${RESET}"
echo "Uptime: $(uptime -p)"
echo "Load: $(uptime | awk -F'load average:' '{print $2}')"
free -h | grep -E "Mem:|Swap:"
df -h / | grep -v Filesystem
echo ""

# rTorrent
echo -e "${CYAN}=== rTorrent ===${RESET}"
RTORRENT_COUNT=$(pgrep -c rtorrent 2>/dev/null || echo 0)
echo "Processes: $RTORRENT_COUNT"
if [ "$RTORRENT_COUNT" -gt 0 ]; then
    ps aux | grep "[r]torrent" | awk '{print "PID: " $2 " | CPU: " $3 "% | MEM: " $4 "% | Runtime: " $10}'

    # Check screen session
    SCREEN_SESSION=$(screen -ls 2>/dev/null | grep rtorrent | awk '{print $1}')
    if [ -n "$SCREEN_SESSION" ]; then
        echo "Screen session: $SCREEN_SESSION"
    fi
fi
display_log_with_errors "rTorrent Execute Log" "/var/log/rtorrent/execute.log" 30 "generic"
display_log_with_errors "rTorrent XMLRPC Log" "/var/log/rtorrent/xmlrpc.log" 20 "generic"
display_log_with_errors "rTorrent Maintenance" "/var/log/rtorrent-maintenance.log" 20 "generic"

# PHP-FPM
echo -e "${CYAN}=== PHP-FPM ===${RESET}"
systemctl status php8.3-fpm --no-pager | grep -E "Active:|Main PID:" | head -2
display_log_with_errors "PHP-FPM Main Log" "/var/log/php8.3-fpm.log" 30 "php_fpm"
display_log_with_errors "PHP-FPM Errors" "/var/log/php8.3-fpm-errors.log" 20 "generic"
display_log_with_errors "PHP-FPM Slow Requests" "/var/log/php8.3-fpm-slow.log" 15 "generic"
display_log_with_errors "PHP-FPM Restart Monitor" "/var/log/php-fpm-monitor.log" 10 "generic"

# Nginx
echo -e "${CYAN}=== Nginx ===${RESET}"
systemctl status nginx --no-pager | grep -E "Active:|Main PID:" | head -2
display_log_with_errors "Nginx Error Log" "/var/log/nginx/error.log" 30 "nginx_error"
display_log_with_errors "ruTorrent Access (last)" "/var/log/nginx/rutorrent-access.log" 15 "nginx_access"

# System alerts
echo -e "${CYAN}=== System Alerts ===${RESET}"
display_log_with_errors "Disk Maintenance" "/var/log/disk-maintenance.log" 20 "generic"
display_log_with_errors "Disk Usage Alerts (>85%)" "/var/log/disk-alerts.log" 15 "generic"
display_log_with_errors "Inode Alerts (>80%)" "/var/log/inode-alerts.log" 15 "generic"
display_log_with_errors "OOM Events" "/var/log/oom-events.log" 15 "generic"

echo -e "${GREEN}=========================================="
echo "         LOG CHECK COMPLETE"
echo -e "==========================================${RESET}"
