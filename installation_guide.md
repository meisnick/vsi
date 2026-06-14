# Vanilla Seedbox Installation & Deployment Guide

This guide details the step-by-step installation process for the **Vanilla Seedbox Stack** (rTorrent, ruTorrent, Nginx, PHP-FPM, and VSFTPD) on a clean installation of **Ubuntu 24.04 LTS (Noble Numbat)**.

---

## 1. Prerequisites & Preparation

Before running the installer, ensure the following conditions are met:
* A fresh, clean server running **Ubuntu 24.04 LTS**.
* You are logged in as a user with `sudo` privileges.
* The repository files are copied/cloned to the server (e.g., in `/tmp/seedbox-installer/` or similar).

### Step 0: Set Script Permissions
Before running the script, make it executable:
```bash
chmod +x setup.sh
```

---

## 2. Interactive Prompts (User Input)

When you execute `sudo ./setup.sh`, the installer will interactively prompt you for inputs to customize the installation:

1. **Username Prompt**: 
   * **Question**: `Enter username to configure for rTorrent/ruTorrent [your_current_user]:`
   * **Behavior**: It auto-detects the non-root user who ran the `sudo` command. You can press `Enter` to accept the default, or type a custom username.
   * **System Action**: If the entered user does not exist, the script will create it.
2. **User Password (if creating a new user)**:
   * **Question**: If a new user is created, the system will trigger standard UNIX prompts:
     `New password:`
     `Retype new password:`
3. **HTTP Basic Auth Password**:
   * **Question**: 
     `Creating HTTP Basic Auth for ruTorrent...`
     `New password:`
     `Re-type new password:`
   * **Behavior**: Prompted by the `htpasswd` utility. This sets the password for logging into the ruTorrent web interface.

---

## 3. Step-by-Step Installation Stages

The installer executes the following stages sequentially:

### Stage 1: Install Package Dependencies
* **Actions**: Runs `apt-get update` and installs core packages:
  * Build dependencies: `build-essential`, `autoconf`, `libtool`, `pkg-config`, `git`, `subversion`, `curl`, `screen`.
  * FTP server: `vsftpd`.
  * Libraries: `libssl-dev`, `libcurl4-openssl-dev`, `libncurses5-dev`, `libxml2-dev`.
  * Web/PHP stack: `nginx`, `php8.3-fpm`, `php8.3-cli`, `php8.3-bcmath`, `php8.3-xml`, `php-pear`, `php-common`, `pkg-php-tools`.

### Stage 2: Compile Core Binaries from Source
* **Actions**: Creates `~/source` in the target user's home directory.
  * **XMLRPC-C**: Checks out the stable branch from Subversion and compiles it (`./configure && make && make install`).
  * **libtorrent (Rakshasa)**: Clones the Git repository, checks out stable tag `v0.15.7`, and compiles it (`./autogen.sh && ./configure && make && make install`).
  * **rTorrent**: Clones the Git repository, checks out stable tag `v0.15.7`, compiles it with XMLRPC-C support (`./autogen.sh && ./configure --with-xmlrpc-c && make && make install`).
  * **ldconfig**: Runs `ldconfig` to register the new shared libraries in `/usr/local/lib`.

### Stage 3: Setup rTorrent Directories & Configuration
* **Actions**: Creates directories `~/rtorrent/download`, `~/rtorrent/watch`, and `~/rtorrent/.session` in the user's home folder.
  * Copies `rtorrent.rc` to `~/.rtorrent.rc`.
  * Replaces the `__USERNAME__` placeholder inside `~/.rtorrent.rc` with the chosen username.
  * Sets ownership (`chown`) of all folders and configuration files to the target user.
  * Sets directory traversal permissions (`chmod g+x`) on the user's home directory so the web server can traverse it to access the SCGI unix socket.

### Stage 4: Install ruTorrent Web Interface
* **Actions**: Clones the `ruTorrent` repository directly into `/var/www/rutorrent/` checking out tag `v5.2.10`.
  * Sets up Basic HTTP Auth in `/etc/nginx/.htpasswd`.
  * Sets ownership of `/var/www/` to `www-data:www-data` so Nginx can access it.
  * Adds `www-data` to the user's system group so Nginx/PHP-FPM can read/write to the rTorrent SCGI socket.
  * Reconfigures ruTorrent `config.php` to point to the local SCGI unix socket (`unix:///home/__USERNAME__/rtorrent/.rtorrent.sock`) and disables TCP socket binding (`$scgi_port = 0`).
  * Copies `rutorrent-plugins.ini` to `/var/www/rutorrent/conf/plugins.ini` to disable the resource-heavy `extratio` and unnecessary `spectrogram` plugins.

### Stage 5: Deploy Nginx, PHP, and System Configurations
* **Actions**: 
  * Copies Nginx sub-configurations `nginx-conf-cache` to `/etc/nginx/conf.d/cache` and `nginx-conf-php` to `/etc/nginx/conf.d/php`.
  * Copies `nginx-site-default` to `/etc/nginx/sites-available/default` (pointing to the correct `.htpasswd` path).
  * Copies `rtorrent.logrotate` to `/etc/logrotate.d/rtorrent` (replacing `__USERNAME__` placeholder).
  * Copies `disk-maintenance.logrotate` to `/etc/logrotate.d/disk-maintenance` to handle log rotations for all maintenance outputs and alert files.
  * Configures PHP-FPM error logging and slowlog (`10s` timeout) in `/etc/php/8.3/fpm/pool.d/www.conf`.
  * Increases system-wide file descriptor limits (hard limit `32768`, soft limit `16384`) in `/etc/security/limits.conf` to handle heavy torrent loads.
  * Tunes kernel parameters in `/etc/sysctl.conf` (`vm.swappiness=1`, `vm.dirty_ratio=10`, `vm.dirty_background_ratio=5`) to optimize swap usage and minimize background disk write bottlenecks.

### Stage 6: Deploy Maintenance Scripts & Cron Jobs
* **Actions**: Copies custom monitoring and diagnostic scripts (`disk-maintenance.sh`, `rtorrent-maintenance.sh`, `monitor-php-fpm.sh`, and `view-all-logs.sh`) to `/usr/local/bin/` and configures execution permissions.
  * Registers cron jobs in `/etc/crontab` to run `monitor-php-fpm.sh` (hourly), `rtorrent-maintenance.sh` (daily), and `disk-maintenance.sh` (weekly on Sundays).
  * Registers system alerts in `/etc/crontab` to log root disk space warnings daily (above 85%), inode usage warnings daily (above 80%), and kernel Out-Of-Memory (OOM) killer events monthly.
  * Replaces the `__USERNAME__` placeholder inside the deployed scripts with the chosen username.

### Stage 7: Configure VSFTPD (FTP Server)
* **Actions**: Overwrites `/etc/vsftpd.conf` with a clean, secured FTP configuration:
  * Listen port: The configured FTP port (randomized between `10000` and `30000` by default).
  * Chroots local users (`chroot_local_user=YES` and `allow_writeable_chroot=YES`).
  * Enforces secure SSL/TLS connection (TLSv1.2+) and disables obsolete SSLv2/SSLv3 protocols.
  * Configures UTF-8 filesystem filename support (`utf8_filesystem=YES`) and disables sendfile (`use_sendfile=NO`) to fix TLS transfer issues.
  * Enables dual logging (`dual_log_enable=YES` and `vsftpd_log_file=/var/log/vsftpd.log`) to facilitate Fail2ban log parsing.
  * Restarts the `vsftpd` service.

### Stage 8: Deploy Systemd Service & Start Stack
* **Actions**:
  * Copies `rtorrent.service` to `/etc/systemd/system/rtorrent.service` (replacing `__USERNAME__` with the target user).
  * Reloads the systemd daemon (`systemctl daemon-reload`) and enables the `rtorrent` service.
  * **Safety Check**: Checks if rTorrent is already running in a `screen` session manually. If running, it skips starting the systemd service to avoid double-session conflicts. If not running, it starts the service.
  * Restarts the `php8.3-fpm` and `nginx` web stack.

### Stage 9: Configure Security & Firewall (UFW / Fail2ban)
* **Actions**: Checks if the user wants to configure the firewall:
  * Applies any SSH Port changes to `/etc/ssh/sshd_config` and restarts SSH services (reloads systemd generator, updates socket activation).
  * Configures default UFW rules (deny incoming, allow outgoing).
  * Opens ports for SSH (detected or randomized port), HTTP (80), HTTPS (443), VSFTPD (randomized port and passive port range 40000-40100), and rTorrent peer ports (51001-51250 TCP/UDP).
  * Enables the UFW firewall.
  * Installs `fail2ban` and deploys `/etc/fail2ban/jail.local` configuring brute-force jails for SSH (configured to use the systemd backend for journald integration), ruTorrent Nginx authentication (`nginx-http-auth`), and FTP logins (`vsftpd`).

### Stage 10: Configure Domain Name & Let's Encrypt (SSL/TLS)
* **Actions**: Prompts the user to optionally configure a custom domain name and Let's Encrypt SSL certificates:
  * Prompts for domain name and email address.
  * Installs `certbot` and `python3-certbot-nginx` via apt.
  * Replaces Nginx default configuration `server_name` with the custom domain.
  * Obtains and installs a valid Let's Encrypt certificate, configuring automatic redirection from HTTP to HTTPS.
  * Automatically updates VSFTPD FTPS certificate parameters in `/etc/vsftpd.conf` (`rsa_cert_file` and `rsa_private_key_file`) to point to the newly obtained Let's Encrypt certificates and restarts the FTP service.

---

## 4. Expected Console Output

The following shows what the console output looks like during a successful installation:

```text
======================================================================
  VANILLA SEEDBOX INSTALLER
======================================================================

Enter username to configure for rTorrent/ruTorrent [seedbox]: seedbox
Configuring stack for user: seedbox (Home: /home/seedbox)

[1/10] Installing package dependencies...
Hit:1 http://archive.ubuntu.com/ubuntu noble InRelease
...
Reading package lists... Done
...
Installing build-essential, nginx, php8.3-fpm, vsftpd, ufw... Done.

[2/10] Compiling core binaries from source...
Checking out xmlrpc-c stable source...
Building xmlrpc-c... Done.
Cloning libtorrent git repository...
Building libtorrent (v0.15.7)... Done.
Cloning rtorrent git repository...
Building rtorrent (v0.15.7) with xmlrpc-c... Done.

[3/10] Setting up rTorrent directories and config...
✓ Configured /home/seedbox/.rtorrent.rc

[4/10] Installing ruTorrent web interface...
Cloning ruTorrent v5.2.10...
Creating HTTP Basic Auth for ruTorrent...
New password: <user types password>
Re-type new password: <user types password>
Adding password for user seedbox

[5/10] Deploying Nginx, PHP, and system configurations...
✓ Copied /etc/nginx/conf.d/cache
✓ Copied /etc/nginx/conf.d/php
✓ Copied /etc/nginx/sites-available/default
✓ Deployed /etc/logrotate.d/rtorrent
✓ Deployed /etc/logrotate.d/disk-maintenance
✓ Tuning PHP-FPM pool configuration...
✓ Setting system-wide open file limits in /etc/security/limits.conf...
✓ Setting kernel performance sysctl variables in /etc/sysctl.conf...

[6/10] Deploying maintenance scripts and cron jobs...
✓ Deployed /usr/local/bin/disk-maintenance.sh
✓ Deployed /usr/local/bin/rtorrent-maintenance.sh
✓ Deployed /usr/local/bin/monitor-php-fpm.sh
Adding Cron Jobs to /etc/crontab...

[7/10] Configuring vsftpd FTP Server...
✓ Configuration written to /etc/vsftpd.conf
✓ Service vsftpd restarted

[8/10] Enabling and starting services...
✓ Systemd unit rtorrent.service deployed.
rTorrent is already running in screen. Skipping systemctl start to prevent conflicts.
✓ Service php8.3-fpm restarted
✓ Service nginx restarted

[9/10] Configuring security & firewall (UFW / Fail2ban)...
Do you want to configure and enable UFW firewall? [Y/n]: y
SSH Port detected: 22
✓ UFW Firewall configured and enabled successfully.
Installing and configuring Fail2ban...
✓ Fail2ban configured and enabled successfully.

[10/10] Configure Domain Name & Let's Encrypt (SSL/TLS)...
Do you want to configure a custom domain and install Let's Encrypt SSL/TLS certificates? [y/N]: y
Enter your domain name (e.g., yourdomain.com): seedbox.example.com
Enter email address for Let's Encrypt alerts: admin@example.com
Installing Certbot Nginx plugin...
✓ Updating server_name to seedbox.example.com in Nginx site default...
Important: Make sure your DNS A/AAAA records for seedbox.example.com point to this server IP before proceeding!
✓ Let's Encrypt SSL/TLS certificate installed successfully for seedbox.example.com!

======================================================================
  VANILLA INSTALLATION AND CONFIGURATION COMPLETED SUCCESSFUL!
  * rTorrent is configured for user 'seedbox'.
  * ruTorrent Basic Auth user is 'seedbox'.
  * SSH service is active on port <randomized_ssh_port>.
  * FTP service is active on port <randomized_ftp_port>.
======================================================================
```

---

## 5. Post-Installation: Accessing the Stack

### A. ruTorrent Web Panel
* **URL**: `https://your-server-ip/rutorrent/`
* **Credentials**:
  * **Username**: The target username configured during install (e.g., `seedbox`).
  * **Password**: The password you typed during the HTTP Basic Auth prompt.

### B. FTP Access
* **Host**: `your-server-ip`
* **Port**: The configured FTP port (printed in the installer completion summary).
* **Credentials**: Use your UNIX system login credentials (same username/password you use for SSH).

### C. Attaching to rTorrent Screen Console
If you ever want to attach to the text-based ncurses console of rTorrent directly via SSH, run:
```bash
screen -r rtorrent
```
To detach from the console without quitting rTorrent, press the key combination:
`Ctrl + A`, then `D`.
