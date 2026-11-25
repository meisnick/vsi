# Vanilla Seedbox Install (VSI)

A modern, high-performance, and secure installer that deploys a clean, generic **Vanilla Seedbox Stack** on **Ubuntu 24.04 LTS (Noble Numbat)**.

This installer compiles the core torrent components from source to ensure optimal performance and implements modern security best practices (including bcrypt authentication hashing, dynamic firewall configuration, and SSL/TLS encryption).

---

## 🚀 Stack Components & Features

* **rTorrent & libtorrent (v0.16.28)**: Compiled from source with XMLRPC-C support for maximum reliability and SCGI communication.
* **ruTorrent (v5.3.25)**: The feature-rich web interface for rTorrent, secured with high-entropy **bcrypt** (`$2y$`) HTTP basic authentication.
* **Web Stack**: Nginx configured with SSL/TLS caching optimizations, paired with the PHP 8.3 FPM runtime.
* **Secured FTP (VSFTPD)**: FTP server configured on a secure custom port (randomized between `10000` and `30000` by default) with forced secure TLSv1.2+ encryption, UTF-8 filesystem support, and writable chroot isolation.
* **Dynamic Firewall (UFW)**: Auto-detects the active SSH port to prevent lockouts, then configures secure incoming rules allowing only SSH, HTTP, HTTPS, FTP, and rTorrent peer ports.
* **Kernel & Resource Optimization**: 
  * Configures high-performance file descriptor limits (hard limit `32768`, soft limit `16384`) in `/etc/security/limits.conf` for login sessions, and `LimitNOFILE=32768` on the `rtorrent` systemd service (which `limits.conf` does not cover).
  * Optimizes memory management and disk write bottlenecks in `/etc/sysctl.conf` (`vm.swappiness=1`, `vm.dirty_ratio=10`, `vm.dirty_background_ratio=5`).
* **Automated Maintenance**: Registers cron jobs, custom monitoring scripts, and diagnostic tools:
  * `monitor-php-fpm.sh` (hourly): Monitors PHP-FPM service restarts and error logs.
  * `rtorrent-maintenance.sh` (daily): Audits active rTorrent session files and tracks system inode usage.
  * `disk-maintenance.sh` (weekly): Scans local filesystems for errors and read-only remounts, reports LVM (when present), and logs disk utilization.
  * `view-all-logs.sh` (utility): A comprehensive system diagnostic tool that scans and summarizes status and highlights errors/warnings across all application and system logs.
  * `system-alerts.sh` (daily/monthly): Logs alerts if root disk usage exceeds 85% or inode usage exceeds 80%, and records kernel OOM-killer events monthly.
  * All jobs are installed in `/etc/cron.d/vsi-maintenance` (rewritten on every run).
* **Centralized Log Rotation**: Deploys automated logrotate configurations for rTorrent, web, maintenance, and system alert logs.

---

## 🛠️ Installation

### 1. Prerequisites
* A fresh, clean server running **Ubuntu 24.04 LTS**.
* Standard `sudo` privileges on the server.

### 2. Quick Start for Absolute Beginners
Follow these simple commands to download the repository onto your server and start the installer:

```bash
# Step 1: Update your server packages and install git
sudo apt-get update && sudo apt-get install -y git

# Step 2: Clone the repository to your server
# Note: For private repositories, you will be prompted for your GitHub username and password/token.
git clone https://github.com/meisnick/vsi.git

# Step 3: Enter the repository directory
cd vsi

# Step 4: Make the installer script executable
chmod +x setup.sh

# Step 5: Run the setup script as root
sudo ./setup.sh
```

### 3. How to Update Later (Git Pull)
If you ever make changes to this repository on GitHub or want to download the latest security updates and improvements onto your active server, run these commands:

```bash
# Step 1: Navigate to the installer directory
cd ~/vsi

# Step 2: Pull the latest updates from GitHub
git pull

# Step 3: (Optional) Re-run the installer if configurations changed
sudo ./setup.sh
```

**Re-runs are safe:** the installer records its choices in `/etc/vsi.conf` (root-only). On a re-run it offers to keep the existing SSH/FTP ports (default **yes**), and re-applies an existing Let's Encrypt certificate and domain to Nginx and VSFTPD instead of reverting to the self-signed certificate. Your previous `~/.rtorrent.rc` is backed up as `~/.rtorrent.rc.bak.<timestamp>` before the template is re-deployed.

### 4. Interactive Prompts
During installation, the script will prompt you for:
1. **Username**: The system user under which rTorrent and the download directories will run (will be created if it doesn't exist).
2. **ruTorrent Web Password**: Sets up the secure bcrypt-hashed password for logging into the ruTorrent web panel.
3. **UFW Firewall, Fail2ban & Port Randomization**: Options to randomize the SSH and FTP ports (between `10000` and `30000` for security), configure UFW firewall rules, and setup Fail2ban protection for SSH, HTTP Auth, and FTP.
   * An SSH port change must be confirmed by typing the new port. **Open that port in any provider/cloud firewall first**, and test a new login before closing your current session.
   * If UFW is already active, the new SSH port is allowed before sshd moves, even if you decline the UFW prompt.
   * Fail2ban bans through UFW when it is active, otherwise directly through nftables.
4. **Domain & Let's Encrypt SSL**: Prompts to optionally enter a custom domain name and email address to automatically configure Let's Encrypt SSL certificates (Certbot) with HTTP-to-HTTPS redirect.

---

## 🔑 Post-Installation: Accessing the Stack

### A. ruTorrent Web Panel
* **URL**: `https://your-server-ip/rutorrent/` (or `https://your-domain/rutorrent/` if configured with Let's Encrypt)
* **Username**: The configured system username.
* **Password**: The password entered during the HTTP Basic Auth prompt.
* *Note: The web server uses the Let's Encrypt SSL/TLS certificate if configured during Stage 10, or falls back to standard self-signed certificates.*

### B. FTP Access
* **Host**: `your-server-ip`
* **Port**: The custom FTP port generated during installation (printed in the completion summary).
* **Protocol**: FTP over Explicit TLS (FTPES / Explicit FTPS)
* **Credentials**: Use your standard system login credentials (same username/password used for SSH).

### C. Attaching to the rTorrent Console
To attach directly to the interactive, text-based ncurses interface of rTorrent running in the background, log in **as the rTorrent user** (screen sessions are per-user) and run:
```bash
screen -r rtorrent
```
The `rtorrent` systemd service restarts rTorrent automatically if it exits; use `sudo systemctl stop rtorrent` to stop it.
*To detach from the console without stopping the torrent client, press `Ctrl + A`, then `D`.*

---

## 📂 Repository File Structure

* `setup.sh`: The master installation script.
* `installation_guide.md`: Detailed stage-by-stage guide of the installation process.
* `rtorrent.rc`: The base configuration template for rTorrent.
* `rutorrent-plugins.ini`: Customized plugin configuration template for ruTorrent (disables extratio and spectrogram).
* `rtorrent.service`: Systemd service unit configuration (raised open-file limit, auto-restart).
* `nginx-site-default`: Default Nginx site configuration block.
* `nginx-conf-php` / `nginx-conf-cache`: PHP-FPM and static cache block helper configurations.
* `rtorrent.logrotate` / `disk-maintenance.logrotate`: Centralized log rotation configurations.
* `monitor-php-fpm.sh` / `rtorrent-maintenance.sh` / `disk-maintenance.sh` / `system-alerts.sh` / `view-all-logs.sh`: Monitoring, alerting, and diagnostic log-checking scripts.

---

## 🔒 License
This installer stack is open-source and customizable for public and private use. Make sure to audit firewall rules and certificate paths when deploying to production environments.
