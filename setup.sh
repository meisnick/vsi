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

# Pinned upstream source commits (verified after checkout for supply-chain safety)
LIBTORRENT_SHA="ee92e30316095c8a9a01372c60d48cf84f11a0e2"  # tag v0.15.7
RTORRENT_SHA="d3ecc83b328b15351e673ada14a7573c482f3363"   # tag v0.15.7

# SSH and FTP port randomization
SSH_PORT=22
FTP_PORT=47260

read -p "Do you want to randomize SSH and FTP listening ports for security? [Y/n]: " RANDOMIZE_PORTS
RANDOMIZE_PORTS=${RANDOMIZE_PORTS:-Y}

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
    # Detect current SSH port
    CURRENT_SSH=$(grep -E "^Port " /etc/ssh/sshd_config | awk '{print $2}' || true)
    if [ -z "$CURRENT_SSH" ]; then
        CURRENT_SSH=$(ss -tlnp | grep -E "sshd|systemd" | grep -v "127.0.0.1" | awk '{print $4}' | awk -F: '{print $NF}' | sort -u | head -n1 || true)
    fi
    SSH_PORT=${CURRENT_SSH:-22}
    echo -e "Using default/existing ports: SSH Port = $SSH_PORT, FTP Port = $FTP_PORT"
fi

echo -e "${CYAN}Configuring stack for user: $USERNAME (Home: $USER_HOME)${RESET}"

# ==============================================================================
#  1. INSTALL DEPENDENCIES & PACKAGE STACK
# ==============================================================================
echo -e "\n${CYAN}[1/10] Installing package dependencies...${RESET}"
apt-get update

# Install build tools, screen, git, vsftpd, and library dependencies
apt-get install -y build-essential autoconf libtool pkg-config git subversion \
    curl screen vsftpd libssl-dev libcurl4-openssl-dev libncurses5-dev libxml2-dev ufw

# Install Nginx and PHP 8.3 FPM stack
apt-get install -y nginx php8.3-fpm php8.3-cli php8.3-bcmath php8.3-xml php-pear php-common pkg-php-tools

# ==============================================================================
#  2. COMPILE XMLRPC-C, LIBTORRENT, & RTORRENT FROM SOURCE
# ==============================================================================
echo -e "\n${CYAN}[2/10] Compiling core binaries from source...${RESET}"
mkdir -p "$SOURCE_DIR"
chown -R "$USERNAME:$USERNAME" "$SOURCE_DIR"

# A. Compile XMLRPC-C
if [ ! -d "$SOURCE_DIR/xmlrpc" ]; then
    echo -e "${YELLOW}Checking out xmlrpc-c stable source...${RESET}"
    svn checkout https://svn.code.sf.net/p/xmlrpc-c/code/stable "$SOURCE_DIR/xmlrpc"
    chown -R "$USERNAME:$USERNAME" "$SOURCE_DIR/xmlrpc"
fi
echo -e "${YELLOW}Building xmlrpc-c...${RESET}"
cd "$SOURCE_DIR/xmlrpc"
./configure
make
make install

# B. Compile Libtorrent (version 0.15.7)
if [ ! -d "$SOURCE_DIR/libtorrent-git" ]; then
    echo -e "${YELLOW}Cloning libtorrent git repository...${RESET}"
    git clone https://github.com/rakshasa/libtorrent.git "$SOURCE_DIR/libtorrent-git"
    chown -R "$USERNAME:$USERNAME" "$SOURCE_DIR/libtorrent-git"
fi
echo -e "${YELLOW}Building libtorrent (pinned v0.15.7 / $LIBTORRENT_SHA)...${RESET}"
cd "$SOURCE_DIR/libtorrent-git"
git fetch --tags origin
git checkout "$LIBTORRENT_SHA"
if [ "$(git rev-parse HEAD)" != "$LIBTORRENT_SHA" ]; then
    echo -e "${RED}Error: libtorrent checkout does not match pinned commit $LIBTORRENT_SHA. Aborting.${RESET}"
    exit 1
fi
./autogen.sh
./configure
make
make install

# C. Compile rTorrent (version 0.15.7)
if [ ! -d "$SOURCE_DIR/rtorrent-git" ]; then
    echo -e "${YELLOW}Cloning rtorrent git repository...${RESET}"
    git clone https://github.com/rakshasa/rtorrent.git "$SOURCE_DIR/rtorrent-git"
    chown -R "$USERNAME:$USERNAME" "$SOURCE_DIR/rtorrent-git"
fi
echo -e "${YELLOW}Building rtorrent (pinned v0.15.7 / $RTORRENT_SHA) with xmlrpc-c...${RESET}"
cd "$SOURCE_DIR/rtorrent-git"
git fetch --tags origin
git checkout "$RTORRENT_SHA"
if [ "$(git rev-parse HEAD)" != "$RTORRENT_SHA" ]; then
    echo -e "${RED}Error: rtorrent checkout does not match pinned commit $RTORRENT_SHA. Aborting.${RESET}"
    exit 1
fi
./autogen.sh
./configure --with-xmlrpc-c
make
make install

# Reload shared library cache
ldconfig

# ==============================================================================
#  3. CONFIGURE RTORRENT FOR USER
# ==============================================================================
echo -e "\n${CYAN}[3/10] Setting up rTorrent directories and config...${RESET}"
mkdir -p "$RTORRENT_DIR/download" "$RTORRENT_DIR/watch" "$RTORRENT_DIR/.session"

# Copy rtorrent.rc config template and replace username placeholder
if [ -f rtorrent.rc ]; then
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

if [ ! -d /var/www/rutorrent ]; then
    echo -e "${YELLOW}Cloning ruTorrent v5.2.10...${RESET}"
    git clone --branch v5.2.10 https://github.com/Novik/ruTorrent.git /var/www/rutorrent
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

if [ -f nginx-site-default ]; then
    cp nginx-site-default /etc/nginx/sites-available/default
    sed -i "s/auth_basic_user_file.*/auth_basic_user_file \/etc\/nginx\/.htpasswd;/g" /etc/nginx/sites-available/default
fi

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

# Configure Cron Jobs in /etc/crontab
if ! grep -q "monitor-php-fpm.sh" /etc/crontab; then
    echo -e "${YELLOW}Adding Cron Jobs to /etc/crontab...${RESET}"
    cat >> /etc/crontab << 'EOF'

# --- Vanilla Seedbox System Maintenance Cron Jobs ---
0  *    * * *   root    /usr/local/bin/monitor-php-fpm.sh
0  4    * * *   root    /usr/local/bin/rtorrent-maintenance.sh
0  3    * * 0   root    /usr/local/bin/disk-maintenance.sh

# Daily disk usage alert if above 85%
0  8    * * *   root    [ $(df / | awk 'NR==2 {print $5}' | sed 's/%//') -gt 85 ] && echo "$(date): Root disk usage: $(df -h / | awk 'NR==2 {print $5}')" >> /var/log/disk-alerts.log

# Alert if inode usage above 80%
0  8    * * *   root    [ $(df -i / | awk 'NR==2 {print $5}' | sed 's/%//') -gt 80 ] && echo "$(date): Inode usage: $(df -i / | awk 'NR==2 {print $5}')" >> /var/log/inode-alerts.log

# Monthly check for OOM events
0  9    1 * *   root    grep -i "out of memory\|killed process" /var/log/syslog* 2>/dev/null >> /var/log/oom-events.log
EOF
fi

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
rsa_cert_file=/etc/ssl/certs/ssl-cert-snakeoil.pem
rsa_private_key_file=/etc/ssl/private/ssl-cert-snakeoil.key
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
    
    # Check if rtorrent is already running manually in screen before starting
    if ! screen -list | grep -q "rtorrent"; then
        echo -e "${YELLOW}Starting systemd rtorrent service...${RESET}"
        systemctl start rtorrent
    else
        echo -e "${YELLOW}rTorrent is already running in screen. Skipping systemctl start to prevent conflicts.${RESET}"
    fi
fi

# Restart Nginx and PHP-FPM
systemctl restart php8.3-fpm
systemctl restart nginx

# ==============================================================================
#  9. CONFIGURE SECURITY & FIREWALL (UFW / FAIL2BAN)
# ==============================================================================
echo -e "\n${CYAN}[9/10] Configuring security & firewall (UFW / Fail2ban)...${RESET}"

# A. Apply SSH Port change if it differs from active setting
CURRENT_SSH=$(grep -E "^Port " /etc/ssh/sshd_config | awk '{print $2}' || true)
if [ -n "$SSH_PORT" ] && [ "$SSH_PORT" != "$CURRENT_SSH" ]; then
    echo -e "${YELLOW}Applying SSH Port change from '${CURRENT_SSH:-22}' to '$SSH_PORT'...${RESET}"
    # Remove existing Port directives to avoid duplicates
    sed -i '/^Port /d' /etc/ssh/sshd_config
    sed -i '/^#Port /d' /etc/ssh/sshd_config
    echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
    
    # Reload systemd generator and restart SSH services (non-disruptive for current shell)
    systemctl daemon-reload
    systemctl restart ssh.socket ssh.service || systemctl restart sshd || true
    echo -e "${GREEN}✓ SSH Port successfully configured to $SSH_PORT.${RESET}"
    echo -e "${YELLOW}Note: Your current SSH connection will remain active, but you must use port $SSH_PORT for all new logins!${RESET}"
fi

read -p "Do you want to configure and enable UFW firewall? [Y/n]: " CONFIRM_UFW
CONFIRM_UFW=${CONFIRM_UFW:-Y}

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

cat << EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 10m
findtime = 10m
maxretry = 5
banaction = ufw

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
read -p "Do you want to configure a custom domain and install Let's Encrypt SSL/TLS certificates? [y/N]: " CONFIRM_SSL
CONFIRM_SSL=${CONFIRM_SSL:-N}

if [[ "$CONFIRM_SSL" =~ ^[Yy]$ ]]; then
    read -p "Enter your domain name (e.g., yourdomain.com): " DOMAIN_NAME
    read -p "Enter email address for Let's Encrypt alerts: " EMAIL_ADDR
    
    if [ -n "$DOMAIN_NAME" ] && [ -n "$EMAIL_ADDR" ]; then
        echo -e "${YELLOW}Installing Certbot Nginx plugin...${RESET}"
        apt-get install -y certbot python3-certbot-nginx
        
        # Update Nginx site configuration server_name
        NGINX_DEFAULT="/etc/nginx/sites-available/default"
        if [ -f "$NGINX_DEFAULT" ]; then
            echo "✓ Updating server_name to $DOMAIN_NAME in Nginx site default..."
            sed -i "s/server_name _;/server_name $DOMAIN_NAME;/g" "$NGINX_DEFAULT"
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

