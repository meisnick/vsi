#!/bin/bash
# ==============================================================================
#  VANILLA SEEDBOX SETUP SCRIPT
#  Installs and configures a vanilla seedbox stack (rTorrent, ruTorrent,
#  Nginx, PHP-FPM, VSFTPD) on Ubuntu 24.04 LTS (Noble Numbat).
# ==============================================================================

# Exit immediately if a command exits with a non-zero status
set -e

# Color definitions
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
RESET='\033[0m'

echo -e "${GREEN}======================================================================"
echo "  VANILLA SEEDBOX INSTALLER"
echo "======================================================================${RESET}"

# Ensure running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run as root (using sudo).${RESET}"
    exit 1
fi

# Resolve the repository directory so templates are found no matter where the
# script is invoked from (Stage 2 cd's into the source trees).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Persistent installer state (ports, domain) so re-runs keep existing settings
STATE_FILE="/etc/vsi.conf"
PREV_SSH_PORT=""
PREV_FTP_PORT=""
PREV_DOMAIN=""
PREV_EMAIL=""
if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    PREV_SSH_PORT="${VSI_SSH_PORT:-}"
    PREV_FTP_PORT="${VSI_FTP_PORT:-}"
    PREV_DOMAIN="${VSI_DOMAIN:-}"
    PREV_EMAIL="${VSI_EMAIL:-}"
fi

save_state() {
    cat > "$STATE_FILE" << EOF
# Vanilla Seedbox installer state — read by setup.sh on re-runs
VSI_USER="$USERNAME"
VSI_SSH_PORT="$SSH_PORT"
VSI_FTP_PORT="$FTP_PORT"
VSI_DOMAIN="${DOMAIN_NAME:-$PREV_DOMAIN}"
VSI_EMAIL="${EMAIL_ADDR:-$PREV_EMAIL}"
EOF
    chmod 600 "$STATE_FILE"
}

# Detect the SSH port sshd is actually configured with (honours sshd_config.d)
detect_ssh_port() {
    local p
    mkdir -p /run/sshd  # sshd -T/-t need it; absent when ssh.socket hasn't spawned sshd
    p=$(sshd -T 2>/dev/null | awk '$1=="port" {print $2; exit}' || true)
    if [ -z "$p" ]; then
        p=$(grep -E "^Port " /etc/ssh/sshd_config | awk '{print $2}' | head -n1 || true)
    fi
    echo "${p:-22}"
}

ufw_active() {
    command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"
}

# Detect OS version
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "$ID" != "ubuntu" ] || [ "$VERSION_ID" != "24.04" ]; then
        echo -e "${YELLOW}Warning: This script was designed for Ubuntu 24.04 LTS (Noble Numbat).${RESET}"
        echo -e "${YELLOW}Your OS is detected as $NAME $VERSION_ID. Proceeding anyway...${RESET}"
    fi
else
    echo -e "${YELLOW}Warning: OS release information not found. Proceeding...${RESET}"
fi

# Configuration Variables (Auto-detect invoking user)
DEFAULT_USER="${SUDO_USER:-seedbox}"
read -p "Enter username to configure for rTorrent/ruTorrent [$DEFAULT_USER]: " USERNAME
USERNAME=${USERNAME:-$DEFAULT_USER}

# Check if user exists
if ! id "$USERNAME" >/dev/null 2>&1; then
    echo -e "${YELLOW}User '$USERNAME' does not exist. Creating user...${RESET}"
    useradd -m -s /bin/bash "$USERNAME"
    passwd "$USERNAME"
fi

# User home and paths
USER_HOME="/home/$USERNAME"
SOURCE_DIR="$USER_HOME/source"
RTORRENT_DIR="$USER_HOME/rtorrent"

# Pinned upstream sources (verified after checkout for supply-chain safety)
XMLRPC_REV="3344"                                           # svn stable r3344 = xmlrpc-c 1.67.02
LIBTORRENT_SHA="392030e0fddbe4e423d059d9322382cf44aaaaf6"  # tag v0.16.28
RTORRENT_SHA="0c23d278a7838402d4cec9689bf71e051332be67"   # tag v0.16.28
RUTORRENT_TAG="v5.3.25"
RUTORRENT_SHA="91f966a01bc35a25598ce7f024855625113b31d7"  # tag v5.3.25
JOBS="$(nproc 2>/dev/null || echo 1)"

# SSH and FTP port randomization
SSH_PORT=22
FTP_PORT=47260
RANDOMIZE_PORTS=N

if [ -n "$PREV_SSH_PORT" ] && [ -n "$PREV_FTP_PORT" ]; then
    # Re-run: keep the ports chosen last time unless explicitly asked to change
    echo -e "${CYAN}Previous install detected ($STATE_FILE): SSH Port = $PREV_SSH_PORT, FTP Port = $PREV_FTP_PORT${RESET}"
    read -p "Keep these ports? [Y/n]: " KEEP_PORTS
    KEEP_PORTS=${KEEP_PORTS:-Y}
    if [[ "$KEEP_PORTS" =~ ^[Yy]$ ]]; then
        SSH_PORT="$PREV_SSH_PORT"
        FTP_PORT="$PREV_FTP_PORT"
    else
        read -p "Randomize new SSH and FTP ports? [y/N]: " RANDOMIZE_PORTS
        RANDOMIZE_PORTS=${RANDOMIZE_PORTS:-N}
        SSH_PORT=$(detect_ssh_port)
        FTP_PORT="$PREV_FTP_PORT"
    fi
else
    read -p "Do you want to randomize SSH and FTP listening ports for security? [Y/n]: " RANDOMIZE_PORTS
    RANDOMIZE_PORTS=${RANDOMIZE_PORTS:-Y}
    SSH_PORT=$(detect_ssh_port)
fi

if [[ "$RANDOMIZE_PORTS" =~ ^[Yy]$ ]]; then
    # Generate random ports between 10000 and 30000
    SSH_PORT=$(shuf -i 10000-30000 -n 1)
    # Ensure FTP port is different
    while true; do
        FTP_PORT=$(shuf -i 10000-30000 -n 1)
        [ "$FTP_PORT" -ne "$SSH_PORT" ] && break
    done
    echo -e "${GREEN}✓ Randomized ports selected: SSH Port = $SSH_PORT, FTP Port = $FTP_PORT${RESET}"
else
    echo -e "Using default/existing ports: SSH Port = $SSH_PORT, FTP Port = $FTP_PORT"
fi

# Warn loudly before an SSH port change — a provider/cloud firewall that only
# allows the old port will lock you out of new sessions.
ACTIVE_SSH_PORT=$(detect_ssh_port)
if [ "$SSH_PORT" != "$ACTIVE_SSH_PORT" ]; then
    echo -e "${RED}WARNING: SSH will move from port $ACTIVE_SSH_PORT to port $SSH_PORT.${RESET}"
    echo -e "${YELLOW}If your hosting provider has an external firewall/security group, open TCP $SSH_PORT there FIRST.${RESET}"
    read -p "Type the new SSH port ($SSH_PORT) to confirm, or press Enter to keep port $ACTIVE_SSH_PORT: " CONFIRM_SSH_PORT
    if [ "$CONFIRM_SSH_PORT" != "$SSH_PORT" ]; then
        SSH_PORT="$ACTIVE_SSH_PORT"
        echo -e "Keeping SSH on port $SSH_PORT."
    fi
fi

echo -e "${CYAN}Configuring stack for user: $USERNAME (Home: $USER_HOME)${RESET}"

# ==============================================================================
#  1. INSTALL DEPENDENCIES & PACKAGE STACK
# ==============================================================================
echo -e "\n${CYAN}[1/10] Installing package dependencies...${RESET}"
apt-get update

# Install build tools, screen, git, vsftpd, and library dependencies
apt-get install -y build-essential autoconf libtool pkg-config git subversion \
    curl screen vsftpd libssl-dev libcurl4-openssl-dev libncurses5-dev libxml2-dev ufw \
    ssl-cert

# Self-signed fallback cert used by nginx and vsftpd until Let's Encrypt is configured
if [ ! -f /etc/ssl/certs/ssl-cert-snakeoil.pem ] || [ ! -f /etc/ssl/private/ssl-cert-snakeoil.key ]; then
    make-ssl-cert generate-default-snakeoil --force-overwrite
fi

# Install Nginx and PHP 8.3 FPM stack
# ruTorrent 5.3+ checks PHP extensions at load and disables plugins whose
# extension is missing (mbstring: _getdir/xmpp/create; curl: telegram; zip: source)
apt-get install -y nginx php8.3-fpm php8.3-cli php8.3-bcmath php8.3-xml php8.3-mbstring \
    php8.3-curl php8.3-zip php-pear php-common pkg-php-tools

# ==============================================================================
#  2. COMPILE XMLRPC-C, LIBTORRENT, & RTORRENT FROM SOURCE
# ==============================================================================
echo -e "\n${CYAN}[2/10] Compiling core binaries from source...${RESET}"
mkdir -p "$SOURCE_DIR"
chown -R "$USERNAME:$USERNAME" "$SOURCE_DIR"

# Source trees are owned by $USERNAME but git runs as root here; mark them safe
# so git's ownership check doesn't abort the build ("dubious ownership").
GIT_SAFE=(-c "safe.directory=$SOURCE_DIR/libtorrent-git" -c "safe.directory=$SOURCE_DIR/rtorrent-git")

# A. Compile XMLRPC-C (pinned svn revision)
if [ ! -d "$SOURCE_DIR/xmlrpc" ]; then
    echo -e "${YELLOW}Checking out xmlrpc-c stable source (r$XMLRPC_REV)...${RESET}"
    svn checkout -r "$XMLRPC_REV" https://svn.code.sf.net/p/xmlrpc-c/code/stable "$SOURCE_DIR/xmlrpc"
else
    svn update -r "$XMLRPC_REV" "$SOURCE_DIR/xmlrpc"
fi
chown -R "$USERNAME:$USERNAME" "$SOURCE_DIR/xmlrpc"
if [ "$(svn info --show-item revision "$SOURCE_DIR/xmlrpc")" != "$XMLRPC_REV" ]; then
    echo -e "${RED}Error: xmlrpc-c checkout does not match pinned revision r$XMLRPC_REV. Aborting.${RESET}"
    exit 1
fi
echo -e "${YELLOW}Building xmlrpc-c (pinned r$XMLRPC_REV)...${RESET}"
cd "$SOURCE_DIR/xmlrpc"
./configure
make -j"$JOBS"
make install

# B. Compile Libtorrent (version 0.16.28)
if [ ! -d "$SOURCE_DIR/libtorrent-git" ]; then
    echo -e "${YELLOW}Cloning libtorrent git repository...${RESET}"
    git clone https://github.com/rakshasa/libtorrent.git "$SOURCE_DIR/libtorrent-git"
    chown -R "$USERNAME:$USERNAME" "$SOURCE_DIR/libtorrent-git"
fi
echo -e "${YELLOW}Building libtorrent (pinned v0.16.28 / $LIBTORRENT_SHA)...${RESET}"
cd "$SOURCE_DIR/libtorrent-git"
git "${GIT_SAFE[@]}" fetch --tags origin
git "${GIT_SAFE[@]}" checkout "$LIBTORRENT_SHA"
if [ "$(git "${GIT_SAFE[@]}" rev-parse HEAD)" != "$LIBTORRENT_SHA" ]; then
    echo -e "${RED}Error: libtorrent checkout does not match pinned commit $LIBTORRENT_SHA. Aborting.${RESET}"
    exit 1
fi
autoreconf -ivf   # 0.16 tags ship no autogen.sh
./configure
make -j"$JOBS"
make install

# C. Compile rTorrent (version 0.16.28)
if [ ! -d "$SOURCE_DIR/rtorrent-git" ]; then
    echo -e "${YELLOW}Cloning rtorrent git repository...${RESET}"
    git clone https://github.com/rakshasa/rtorrent.git "$SOURCE_DIR/rtorrent-git"
    chown -R "$USERNAME:$USERNAME" "$SOURCE_DIR/rtorrent-git"
fi
echo -e "${YELLOW}Building rtorrent (pinned v0.16.28 / $RTORRENT_SHA) with xmlrpc-c...${RESET}"
cd "$SOURCE_DIR/rtorrent-git"
git "${GIT_SAFE[@]}" fetch --tags origin
git "${GIT_SAFE[@]}" checkout "$RTORRENT_SHA"
if [ "$(git "${GIT_SAFE[@]}" rev-parse HEAD)" != "$RTORRENT_SHA" ]; then
    echo -e "${RED}Error: rtorrent checkout does not match pinned commit $RTORRENT_SHA. Aborting.${RESET}"
    exit 1
fi
autoreconf -ivf   # 0.16 tags ship no autogen.sh
./configure --with-xmlrpc-c
make -j"$JOBS"
make install

# Reload shared library cache
ldconfig

# Return to the repository so the templates below resolve correctly
cd "$SCRIPT_DIR"

# ==============================================================================
#  3. CONFIGURE RTORRENT FOR USER
# ==============================================================================
echo -e "\n${CYAN}[3/10] Setting up rTorrent directories and config...${RESET}"
mkdir -p "$RTORRENT_DIR/download" "$RTORRENT_DIR/watch" "$RTORRENT_DIR/.session"

# rTorrent writes its execute/event log here (see rtorrent.rc); it refuses to
# start if the directory is missing or not writable by the rTorrent user.
mkdir -p /var/log/rtorrent
chown "$USERNAME:$USERNAME" /var/log/rtorrent
chmod 755 /var/log/rtorrent

# Copy rtorrent.rc config template and replace username placeholder
if [ -f rtorrent.rc ]; then
    if [ -f "$USER_HOME/.rtorrent.rc" ]; then
        cp "$USER_HOME/.rtorrent.rc" "$USER_HOME/.rtorrent.rc.bak.$(date +%Y%m%d%H%M%S)"
    fi
    cp rtorrent.rc "$USER_HOME/.rtorrent.rc"
    sed -i "s/__USERNAME__/$USERNAME/g" "$USER_HOME/.rtorrent.rc"
else
    echo -e "${RED}Error: rtorrent.rc template not found!${RESET}"
    exit 1
fi

# Set permissions
chown -R "$USERNAME:$USERNAME" "$RTORRENT_DIR"
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.rtorrent.rc"

# Ensure www-data (added to the user's group in Stage 4) can traverse the home
# directory to reach the rTorrent SCGI socket, without opening it to others.
chmod g+x "$USER_HOME"

# ==============================================================================
#  4. INSTALL RUTORRENT WEB INTERFACE
# ==============================================================================
echo -e "\n${CYAN}[4/10] Installing ruTorrent web interface...${RESET}"
mkdir -p /var/www

RUT_GIT=(git -c "safe.directory=/var/www/rutorrent" -C /var/www/rutorrent)
if [ ! -d /var/www/rutorrent ]; then
    echo -e "${YELLOW}Cloning ruTorrent $RUTORRENT_TAG...${RESET}"
    git clone --branch "$RUTORRENT_TAG" https://github.com/Novik/ruTorrent.git /var/www/rutorrent
elif [ -d /var/www/rutorrent/.git ] && [ "$("${RUT_GIT[@]}" rev-parse HEAD)" != "$RUTORRENT_SHA" ]; then
    # Upgrade an earlier install in place. conf/config.php is tracked and was
    # edited below on the previous run, so keep a copy and let the edits below
    # re-apply to the new upstream file; conf/users/ and share/ are untracked
    # and survive the checkout.
    echo -e "${YELLOW}Upgrading ruTorrent to $RUTORRENT_TAG...${RESET}"
    cp -a /var/www/rutorrent/conf/config.php "/var/www/rutorrent/conf/config.php.bak.$(date +%Y%m%d%H%M%S)"
    "${RUT_GIT[@]}" fetch --tags origin
    "${RUT_GIT[@]}" checkout -f "$RUTORRENT_SHA"
fi
if [ -d /var/www/rutorrent/.git ] && [ "$("${RUT_GIT[@]}" rev-parse HEAD)" != "$RUTORRENT_SHA" ]; then
    echo -e "${RED}Error: ruTorrent checkout does not match pinned commit $RUTORRENT_SHA. Aborting.${RESET}"
    exit 1
fi

# Create default basic auth htpasswd if not exists
if [ ! -f /etc/nginx/.htpasswd ]; then
    echo -e "${YELLOW}Creating HTTP Basic Auth for ruTorrent...${RESET}"
    apt-get install -y apache2-utils
    htpasswd -B -c /etc/nginx/.htpasswd "$USERNAME"
fi

# Allow nginx/PHP-FPM (www-data) to reach rTorrent's SCGI unix socket via group membership
usermod -aG "$USERNAME" www-data

# Point ruTorrent at the rTorrent SCGI unix socket instead of a TCP port
RUT_CONF="/var/www/rutorrent/conf/config.php"
if [ -f "$RUT_CONF" ]; then
    echo -e "${YELLOW}Pointing ruTorrent at the rTorrent SCGI unix socket...${RESET}"
    sed -i "s|^[[:space:]]*\$scgi_port[[:space:]]*=.*|\$scgi_port = 0;|" "$RUT_CONF"
    sed -i "s|^[[:space:]]*\$scgi_host[[:space:]]*=.*|\$scgi_host = \"unix://$RTORRENT_DIR/.rtorrent.sock\";|" "$RUT_CONF"
fi

# Deploy customized plugins.ini to disable problematic/unnecessary plugins (extratio, spectrogram)
if [ -f rutorrent-plugins.ini ]; then
    echo -e "${YELLOW}Deploying custom ruTorrent plugins configuration...${RESET}"
    cp rutorrent-plugins.ini /var/www/rutorrent/conf/plugins.ini
fi

# Set ownership of web root to www-data
chown -R www-data:www-data /var/www

# ==============================================================================
#  5. DEPLOY NGINX, PHP, AND SYSTEM CONFIGURATIONS
# ==============================================================================
echo -e "\n${CYAN}[5/10] Deploying Nginx, PHP, and system configurations...${RESET}"

# Deploy caching, PHP, and site configs
[ -f nginx-conf-cache ] && cp nginx-conf-cache /etc/nginx/conf.d/cache
[ -f nginx-conf-php ] && cp nginx-conf-php /etc/nginx/conf.d/php

# TLS certificate shared by nginx and vsftpd: self-signed by default, or the
# Let's Encrypt cert from a previous run so re-running doesn't revert to snakeoil.
TLS_CERT="/etc/ssl/certs/ssl-cert-snakeoil.pem"
TLS_KEY="/etc/ssl/private/ssl-cert-snakeoil.key"
TLS_DOMAIN=""
if [ -n "$PREV_DOMAIN" ] && [ -f "/etc/letsencrypt/live/$PREV_DOMAIN/fullchain.pem" ]; then
    TLS_DOMAIN="$PREV_DOMAIN"
    TLS_CERT="/etc/letsencrypt/live/$PREV_DOMAIN/fullchain.pem"
    TLS_KEY="/etc/letsencrypt/live/$PREV_DOMAIN/privkey.pem"
    echo "✓ Reusing existing Let's Encrypt certificate for $PREV_DOMAIN"
fi

# Rebuild the nginx site from the template, re-applying the domain and certificate
deploy_nginx_site() {
    local site="/etc/nginx/sites-available/default"
    [ -f nginx-site-default ] || return 0
    cp nginx-site-default "$site"
    sed -i "s|auth_basic_user_file.*|auth_basic_user_file /etc/nginx/.htpasswd;|g" "$site"
    sed -i "s|^\([[:space:]]*\)ssl_certificate .*|\1ssl_certificate $TLS_CERT;|" "$site"
    sed -i "s|^\([[:space:]]*\)ssl_certificate_key .*|\1ssl_certificate_key $TLS_KEY;|" "$site"
    if [ -n "$TLS_DOMAIN" ]; then
        sed -i "s/server_name _;/server_name $TLS_DOMAIN;/g" "$site"
    fi
}
deploy_nginx_site

# Deploy logrotate config for rTorrent
if [ -f rtorrent.logrotate ]; then
    cp rtorrent.logrotate /etc/logrotate.d/rtorrent
    sed -i "s/__USERNAME__/$USERNAME/g" /etc/logrotate.d/rtorrent
    chown root:root /etc/logrotate.d/rtorrent
    chmod 644 /etc/logrotate.d/rtorrent
    echo "✓ Deployed /etc/logrotate.d/rtorrent"
fi

# Deploy logrotate config for disk maintenance and system alerts
if [ -f disk-maintenance.logrotate ]; then
    cp disk-maintenance.logrotate /etc/logrotate.d/disk-maintenance
    chown root:root /etc/logrotate.d/disk-maintenance
    chmod 644 /etc/logrotate.d/disk-maintenance
    echo "✓ Deployed /etc/logrotate.d/disk-maintenance"
fi

# Configure PHP-FPM logging and performance options in pool config
PHP_FPM_CONF="/etc/php/8.3/fpm/pool.d/www.conf"
if [ -f "$PHP_FPM_CONF" ]; then
    echo "✓ Tuning PHP-FPM pool configuration..."
    # Ensure slowlog options are set
    sed -i '/^;*slowlog =/c\slowlog = /var/log/php8.3-fpm-slow.log' "$PHP_FPM_CONF"
    sed -i '/^;*request_slowlog_timeout =/c\request_slowlog_timeout = 10s' "$PHP_FPM_CONF"
    # Ensure pool-level error logging is enabled
    if ! grep -q "php_admin_value\[error_log\]" "$PHP_FPM_CONF"; then
        cat >> "$PHP_FPM_CONF" << EOF

# --- Custom ruTorrent Error/Slow Logging ---
php_admin_flag[log_errors] = on
php_admin_value[error_log] = /var/log/php8.3-fpm-errors.log
EOF
    fi
fi

# Configure system-wide limits for open file descriptors
LIMITS_CONF="/etc/security/limits.conf"
if [ -f "$LIMITS_CONF" ] && ! grep -q "nofile 32768" "$LIMITS_CONF"; then
    echo "✓ Setting system-wide open file limits in $LIMITS_CONF..."
    cat >> "$LIMITS_CONF" << EOF

# --- Vanilla Seedbox limits for rTorrent ---
* hard nofile 32768
* soft nofile 16384
EOF
fi

# Configure kernel sysctl settings for seedbox performance
SYSCTL_CONF="/etc/sysctl.conf"
if [ -f "$SYSCTL_CONF" ] && ! grep -q "vm.swappiness=1" "$SYSCTL_CONF"; then
    echo "✓ Setting kernel performance sysctl variables in $SYSCTL_CONF..."
    cat >> "$SYSCTL_CONF" << EOF

# --- Vanilla Seedbox Kernel Tuning ---
vm.swappiness=1
vm.dirty_ratio=10
vm.dirty_background_ratio=5
EOF
    # Apply settings immediately (safeguarded for containers)
    sysctl -p || true
fi



# ==============================================================================
#  6. DEPLOY MAINTENANCE SCRIPTS & CRON JOBS
# ==============================================================================
echo -e "\n${CYAN}[6/10] Deploying maintenance scripts and cron jobs...${RESET}"

# Copy scripts to /usr/local/bin
scripts=(
    "disk-maintenance.sh"
    "rtorrent-maintenance.sh"
    "monitor-php-fpm.sh"
    "system-alerts.sh"
    "view-all-logs.sh"
)

for script in "${scripts[@]}"; do
    if [ -f "$script" ]; then
        cp "$script" "/usr/local/bin/$script"
        sed -i "s/__USERNAME__/$USERNAME/g" "/usr/local/bin/$script"
        chmod +x "/usr/local/bin/$script"
        echo "✓ Deployed /usr/local/bin/$script"
    else
        echo -e "${RED}Warning: $script not found in script directory!${RESET}"
    fi
done

# Remove the legacy cron block older versions appended to /etc/crontab (its
# inline disk/inode alerts never ran: cron treats '%' as a newline).
if grep -q "^# --- Vanilla Seedbox System Maintenance Cron Jobs ---" /etc/crontab; then
    echo -e "${YELLOW}Migrating legacy cron jobs out of /etc/crontab...${RESET}"
    sed -i '/^# --- Vanilla Seedbox System Maintenance Cron Jobs ---$/,/oom-events\.log$/d' /etc/crontab
fi

# Cron jobs live in their own file so re-runs simply overwrite them.
# Keep commands free of '%' — cron converts it to a newline.
cat > /etc/cron.d/vsi-maintenance << 'EOF'
# --- Vanilla Seedbox System Maintenance Cron Jobs (managed by setup.sh) ---
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

0  *    * * *   root    /usr/local/bin/monitor-php-fpm.sh
0  4    * * *   root    /usr/local/bin/rtorrent-maintenance.sh
0  3    * * 0   root    /usr/local/bin/disk-maintenance.sh

# Daily disk (>85%) and inode (>80%) usage alerts
0  8    * * *   root    /usr/local/bin/system-alerts.sh usage

# Monthly check for OOM events (previous month's kernel log)
0  9    1 * *   root    /usr/local/bin/system-alerts.sh oom
EOF
chmod 644 /etc/cron.d/vsi-maintenance
echo "✓ Deployed /etc/cron.d/vsi-maintenance"

# ==============================================================================
#  7. CONFIGURE VSFTPD (FTP SERVER)
# ==============================================================================
echo -e "\n${CYAN}[7/10] Configuring vsftpd FTP Server...${RESET}"
cat << EOF > /etc/vsftpd.conf
listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
dirmessage_enable=YES
use_localtime=YES
xferlog_enable=YES
dual_log_enable=YES
vsftpd_log_file=/var/log/vsftpd.log
connect_from_port_20=YES
chroot_local_user=YES
secure_chroot_dir=/var/run/vsftpd/empty
pam_service_name=vsftpd
rsa_cert_file=$TLS_CERT
rsa_private_key_file=$TLS_KEY
ssl_enable=YES
utf8_filesystem=YES
use_sendfile=NO
allow_anon_ssl=NO
force_local_data_ssl=YES
force_local_logins_ssl=YES
ssl_sslv2=NO
ssl_sslv3=NO
ssl_tlsv1=NO
ssl_tlsv1_1=NO
ssl_tlsv1_2=YES
require_ssl_reuse=NO
ssl_ciphers=HIGH
listen_port=$FTP_PORT
pasv_min_port=40000
pasv_max_port=40100
allow_writeable_chroot=YES
EOF

# Restart vsftpd
systemctl restart vsftpd


# ==============================================================================
#  8. DEPLOY SYSTEMD UNIT & RESTART SERVICES
# ==============================================================================
echo -e "\n${CYAN}[8/10] Enabling and starting services...${RESET}"

if [ -f rtorrent.service ]; then
    cp rtorrent.service /etc/systemd/system/rtorrent.service
    sed -i "s/__USERNAME__/$USERNAME/g" /etc/systemd/system/rtorrent.service
    chown root:root /etc/systemd/system/rtorrent.service
    chmod 644 /etc/systemd/system/rtorrent.service
    
    systemctl daemon-reload
    systemctl enable rtorrent
    
    # Only start rTorrent if the user isn't already running it (via this unit or
    # a manual screen session — screen sessions are per-user, so check processes
    # owned by $USERNAME rather than root's `screen -list`).
    if systemctl is-active --quiet rtorrent; then
        echo -e "${YELLOW}rTorrent service is already running. Run 'sudo systemctl restart rtorrent' to load the new build and config.${RESET}"
    # Match the binary path: the process name differs between versions
    # ('rtorrent main' up to 0.15, 'rtorrent-main' from 0.16).
    elif pgrep -u "$USERNAME" -f '^[^ ]*/rtorrent( |$)' >/dev/null; then
        echo -e "${YELLOW}rTorrent is already running for $USERNAME outside systemd (manual screen?). Skipping systemctl start to prevent conflicts.${RESET}"
    else
        echo -e "${YELLOW}Starting systemd rtorrent service...${RESET}"
        systemctl start rtorrent
    fi
fi

# Restart Nginx and PHP-FPM
systemctl restart php8.3-fpm
systemctl restart nginx

# ==============================================================================
#  9. CONFIGURE SECURITY & FIREWALL (UFW / FAIL2BAN)
# ==============================================================================
echo -e "\n${CYAN}[9/10] Configuring security & firewall (UFW / Fail2ban)...${RESET}"

# A. Apply SSH Port change if it differs from the active setting
CURRENT_SSH=$(detect_ssh_port)
if [ -n "$SSH_PORT" ] && [ "$SSH_PORT" != "$CURRENT_SSH" ]; then
    echo -e "${YELLOW}Applying SSH Port change from '$CURRENT_SSH' to '$SSH_PORT'...${RESET}"

    # Open the new port in an already-active UFW BEFORE sshd moves, so new
    # sessions aren't locked out even if the UFW prompt below is declined.
    if ufw_active; then
        ufw allow "$SSH_PORT"/tcp comment 'SSH'
        echo "✓ Allowed new SSH port $SSH_PORT in the active UFW firewall."
    fi

    # Multiple Port lines make sshd listen on all of them, so comment out every
    # other Port directive and keep the single setting in a dedicated drop-in.
    sed -i 's/^Port /#Port /' /etc/ssh/sshd_config
    grep -l -E "^[[:space:]]*Port " /etc/ssh/sshd_config.d/*.conf 2>/dev/null | grep -v "00-vsi-port.conf" | while read -r f; do
        sed -i 's/^\([[:space:]]*\)Port /\1#Port /' "$f"
    done || true
    echo "Port $SSH_PORT" > /etc/ssh/sshd_config.d/00-vsi-port.conf

    if ! sshd -t; then
        echo -e "${RED}sshd config test failed — reverting SSH port change, staying on $CURRENT_SSH.${RESET}"
        echo "Port $CURRENT_SSH" > /etc/ssh/sshd_config.d/00-vsi-port.conf
        SSH_PORT="$CURRENT_SSH"
    fi

    # Reload systemd generator and restart SSH services (non-disruptive for current shell)
    systemctl daemon-reload
    systemctl restart ssh.socket ssh.service || systemctl restart sshd || true
    echo -e "${GREEN}✓ SSH Port configured to $SSH_PORT.${RESET}"
    echo -e "${YELLOW}Note: Keep this session open and test a NEW login on port $SSH_PORT before disconnecting!${RESET}"
fi
save_state

read -p "Do you want to configure and enable UFW firewall? [Y/n]: " CONFIRM_UFW
CONFIRM_UFW=${CONFIRM_UFW:-Y}

if ! [[ "$CONFIRM_UFW" =~ ^[Yy]$ ]] && ufw_active; then
    # UFW is already enforcing rules; make sure the current SSH/FTP ports are reachable
    echo -e "${YELLOW}UFW is already active — ensuring SSH ($SSH_PORT) and FTP ($FTP_PORT) ports are allowed...${RESET}"
    ufw allow "$SSH_PORT"/tcp comment 'SSH'
    ufw allow "$FTP_PORT"/tcp comment 'FTP Control'
fi

if [[ "$CONFIRM_UFW" =~ ^[Yy]$ ]]; then
    echo "SSH Port to allow in firewall: $SSH_PORT"
    
    # Configure UFW
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "$SSH_PORT"/tcp comment 'SSH'
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    ufw allow "$FTP_PORT"/tcp comment 'FTP Control'
    ufw allow 40000:40100/tcp comment 'FTP Passive'
    ufw allow 51001:51250/tcp comment 'rTorrent Peer TCP'
    ufw allow 51001:51250/udp comment 'rTorrent Peer UDP'
    
    echo "y" | ufw enable
    echo "✓ UFW Firewall configured and enabled successfully."
else
    echo "Skipping UFW firewall configuration."
fi

# Install and configure Fail2ban
echo -e "${YELLOW}Installing and configuring Fail2ban...${RESET}"
apt-get install -y fail2ban

# Ban through UFW only when UFW is actually enforcing; otherwise use nftables
# directly so bans still take effect with UFW declined/disabled.
if ufw_active; then
    F2B_BANACTION="ufw"
else
    F2B_BANACTION="nftables-multiport"
    command -v nft >/dev/null 2>&1 || apt-get install -y nftables
fi
echo "Fail2ban ban action: $F2B_BANACTION"

cat << EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 10m
findtime = 10m
maxretry = 5
banaction = $F2B_BANACTION

[sshd]
enabled = true
port = $SSH_PORT
backend = systemd

[nginx-http-auth]
enabled = true
port = http,https
logpath = /var/log/nginx/error.log
maxretry = 5

[vsftpd]
enabled = true
port = $FTP_PORT
logpath = /var/log/vsftpd.log
maxretry = 5
EOF

systemctl enable fail2ban
systemctl restart fail2ban
echo "✓ Fail2ban configured and enabled successfully."

# ==============================================================================
#  10. CONFIGURE DOMAIN NAME & LET'S ENCRYPT (SSL/TLS)
# ==============================================================================
echo -e "\n${CYAN}[10/10] Configure Domain Name & Let's Encrypt (SSL/TLS)...${RESET}"
if [ -n "$TLS_DOMAIN" ]; then
    # Stage 5/7 already re-applied the existing certificate to nginx and vsftpd
    echo -e "${GREEN}✓ Let's Encrypt is already configured for $TLS_DOMAIN (nginx + vsftpd).${RESET}"
    read -p "Configure a different domain/certificate? [y/N]: " CONFIRM_SSL
else
    read -p "Do you want to configure a custom domain and install Let's Encrypt SSL/TLS certificates? [y/N]: " CONFIRM_SSL
fi
CONFIRM_SSL=${CONFIRM_SSL:-N}

if [[ "$CONFIRM_SSL" =~ ^[Yy]$ ]]; then
    read -p "Enter your domain name (e.g., yourdomain.com): " DOMAIN_NAME
    read -p "Enter email address for Let's Encrypt alerts: " EMAIL_ADDR
    
    if [ -n "$DOMAIN_NAME" ] && [ -n "$EMAIL_ADDR" ]; then
        echo -e "${YELLOW}Installing Certbot Nginx plugin...${RESET}"
        apt-get install -y certbot python3-certbot-nginx
        
        # Update Nginx site configuration server_name (rebuilt from the template
        # so a previously configured domain is replaced cleanly)
        if [ -f nginx-site-default ]; then
            echo "✓ Updating server_name to $DOMAIN_NAME in Nginx site default..."
            TLS_DOMAIN="$DOMAIN_NAME"
            deploy_nginx_site
            systemctl reload nginx
        fi
        
        echo -e "${YELLOW}Important: Make sure your DNS A/AAAA records for $DOMAIN_NAME point to this server IP before proceeding!${RESET}"
        
        # Run certbot in non-interactive mode
        if certbot --nginx -d "$DOMAIN_NAME" --non-interactive --agree-tos -m "$EMAIL_ADDR" --redirect; then
            echo -e "${GREEN}✓ Let's Encrypt SSL/TLS certificate installed successfully for $DOMAIN_NAME!${RESET}"

            # Repoint vsftpd FTPS from the snakeoil cert to the real certificate
            if [ -f /etc/vsftpd.conf ]; then
                echo "✓ Repointing vsftpd FTPS at the Let's Encrypt certificate..."
                sed -i "s|^rsa_cert_file=.*|rsa_cert_file=/etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem|" /etc/vsftpd.conf
                sed -i "s|^rsa_private_key_file=.*|rsa_private_key_file=/etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem|" /etc/vsftpd.conf
                systemctl restart vsftpd || true
            fi

            # Remember the domain so re-runs keep this certificate in place
            save_state
        else
            echo -e "${RED}Warning: Certbot SSL/TLS certificate request failed.${RESET}"
            echo -e "${YELLOW}Please verify your DNS settings and run 'sudo certbot --nginx' manually later.${RESET}"
        fi
    else
        echo -e "${RED}Domain name or email address cannot be empty. Skipping Let's Encrypt configuration.${RESET}"
    fi
else
    echo "Skipping Let's Encrypt configuration."
fi

echo -e "\n${GREEN}======================================================================"
echo "  VANILLA INSTALLATION AND CONFIGURATION COMPLETED SUCCESSFUL!"
echo "  * rTorrent is configured for user '$USERNAME'."
echo "  * ruTorrent Basic Auth user is '$USERNAME'."
echo "  * SSH service is active on port $SSH_PORT."
echo "  * FTP service is active on port $FTP_PORT."
echo "======================================================================${RESET}\n"

echo -e "${YELLOW}Security recommendation: once you have confirmed key-based SSH login works,"
echo -e "disable password authentication to eliminate SSH brute-force attempts:"
echo -e "  ${CYAN}sudo sed -i 's/^#\\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config"
echo -e "  sudo systemctl restart ssh${RESET}\n"

