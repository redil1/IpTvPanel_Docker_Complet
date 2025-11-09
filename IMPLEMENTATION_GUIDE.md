# IPTV Panel – End-to-End Deployment Guide

This document walks a complete beginner through every step of deploying the IPTV Panel from scratch. It covers:

1. Buying and preparing the servers  
2. Pointing DNS and Cloudflare  
3. Running `./deploy.sh` from your workstation  
4. Verifying the installation and using the panel/API  
5. Troubleshooting the common blockers (SSH, Fail2Ban, SSL, etc.)

---

## 1. Understand the System

```
┌──────────────────────────────────────────────────────────────┐
│                       YOUR IPTV SYSTEM                        │
├──────────────────────────────────────────────────────────────┤
│ Panel Server (Contabo)        Streaming Server (Hetzner)      │
│ • Web panel & API             • Nginx + RTMP/HLS               │
│ • PostgreSQL database         • FFmpeg / channel ingestion     │
│ • M3U playlist generator      • Redis token validation         │
│ • Manages users via API       • Serves streams to end users    │
└──────────────────────────────────────────────────────────────┘
                   ▲                           │
                   │ HTTPS + API calls         │ HLS/M3U + tokens
                   │                           ▼
                 Cloudflare CDN  ──>  End users & OTT apps
```

Key domains & IPs used in examples:

| Purpose            | Domain                 | Public IP        |
|--------------------|------------------------|------------------|
| Panel front end    | `panel.goalfete.com`   | `93.127.133.51`  |
| Streaming backend  | `stream.goalfete.com`  | `95.217.193.163` |

Replace these with your own values if you use different providers.

---

## 2. Prerequisites

### 2.1 Buy the Servers

- **Panel server (Contabo)**: Ubuntu 22.04 LTS, at least 2 vCPU, 4 GB RAM, 60 GB SSD.  
  Log in as user `administrator` over SSH.
- **Streaming server (Hetzner)**: Ubuntu 22.04 LTS (or your tuned streaming stack) with Nginx/RTMP, Redis, FFmpeg. Log in as `root`.

Make sure both servers are reachable over the public internet.

### 2.2 Register a Domain

1. Buy a domain (e.g., from Namecheap, GoDaddy).  
2. Move DNS to Cloudflare (free plan is enough).  
3. Create **A records**:
   - `panel.goalfete.com` → `93.127.133.51` (panel server)  
   - `stream.goalfete.com` → `95.217.193.163` (stream server)  
   Disable Cloudflare proxy (“gray cloud”) at first; the deploy script needs to see the real IP when it requests certificates.

### 2.3 Local Workstation Setup

You need a Mac/Linux workstation (or WSL on Windows) with:

| Tool       | Purpose                          | Installation (macOS)                |
|------------|----------------------------------|-------------------------------------|
| `git`      | Clone this repository            | `xcode-select --install`            |
| `ssh`      | Remote access                    | Comes with macOS                    |
| `sshpass`  | Non-interactive SSH in script    | `brew install hudochenkov/sshpass/sshpass` |
| `rsync`    | Sync project files               | Comes with macOS                    |
| `python3`  | Optional local testing           | `brew install python`               |

Clone/download the IPTV Panel project so the `deploy.sh` script is in your working directory.

---

## 3. Prepare Each Server

### 3.1 Panel Server (93.127.133.51)

1. Log in: `ssh administrator@93.127.133.51`
2. Update base system:
   ```bash
   sudo apt update && sudo apt upgrade -y
   ```
3. Make sure the following ports are open on the host firewall and any provider firewall:
   - `22` (SSH)
   - `80`, `443` (HTTP/HTTPS for Certbot)
   - `54321` (panel HTTPS port)
4. If using UFW:
   ```bash
   sudo ufw allow 22/tcp
   sudo ufw allow 80/tcp
   sudo ufw allow 443/tcp
   sudo ufw allow 54321/tcp
   sudo ufw enable
   ```
5. Ensure the `administrator` password matches the value in `deploy.sh` (`REMOTE_PASS`).

### 3.2 Streaming Server (95.217.193.163)

1. Log in: `ssh root@95.217.193.163`
2. Update system: `apt update && apt upgrade -y`
3. Install and enable OpenSSH (should already be running):
   ```bash
   apt install -y openssh-server
   systemctl enable --now ssh
   ```
4. Open port 22 (plus your streaming ports) via UFW or provider firewall.
5. **Fail2Ban**: whitelist the panel server IP to prevent bans.
   ```bash
   sudo tee /etc/fail2ban/jail.local >/dev/null <<'EOF'
   [sshd]
   enabled   = true
   port      = ssh
   logpath   = %(sshd_log)s
   maxretry  = 5
   ignoreip  = 127.0.0.1/8 93.127.133.51
   EOF

   sudo systemctl restart fail2ban
   ```
6. Confirm SSH connectivity **from the panel server**:
   ```bash
   ssh root@95.217.193.163
   ```
   If it succeeds (you reach the password prompt), the deploy script can push SSH keys later.

7. Ensure Redis is running and listening locally—the `/opt/user_manager.sh` script writes tokens to Redis.

---

## 4. What `deploy.sh` Does (Step by Step)

The script lives on your workstation. Key variables at the top (edit if your infrastructure differs):

| Variable            | Default                             | Description                                      |
|---------------------|-------------------------------------|--------------------------------------------------|
| `REMOTE_HOST`       | `93.127.133.51`                     | Panel server IP                                  |
| `REMOTE_USER`       | `administrator`                     | SSH user on panel server                         |
| `REMOTE_PASS`       | `GoldvisioN@1982`                   | Password for `REMOTE_USER`                       |
| `REMOTE_DIR`        | `/opt/IptvPannel`                   | Sync target directory (contains project files)   |
| `INSTALL_SCRIPT`    | `pannel.sh`                         | The large installer executed on the panel server |
| `REMOTE_SSL_SCRIPT` | `remote_ssl_setup.sh`               | Handles Certbot and Nginx SSL config             |
| `STREAM_IP`         | `95.217.193.163`                    | Streaming server IP                              |
| `STREAM_DOMAIN`     | `stream.goalfete.com`               | Used inside `.env` and templates                 |
| `PANEL_DOMAIN`      | `panel.goalfete.com`                | Used for Certbot and Nginx                       |
| `CERTBOT_EMAIL`     | `admin@goalfete.com`                | Email registered with Let’s Encrypt              |

### Execution Flow

> Start in the project directory on your workstation: `/Users/mac/Desktop/IptvPannel`

1. **Pre-flight**
   - Checks for `sshpass`, `rsync`, `ssh`.
   - Confirms both `pannel.sh` and `remote_ssl_setup.sh` exist.
   - Prompts for confirmation (`y` to continue).

2. **Remote directory prep**
   - Uses `sudo -S` on the panel server to create `REMOTE_DIR` and set ownership to `administrator`.

3. **Upload project**
   - `rsync -avz --delete` uploads every file from your local folder to the panel server (excluding `deploy copy*`).

4. **Prepare installer input**
   - Builds the list of answers expected by `pannel.sh` (install path, domains, admin password, etc.).
   - Encodes the answers in base64 to feed them via stdin.

5. **Run `pannel.sh`**
   - Stops any running `iptv-panel` or `nginx` services.
   - Deletes the previous `/opt/iptv-panel` directory to start clean.
   - Runs `./pannel.sh < installer_answers.txt` with `sudo`.
   - That script installs system packages, sets up PostgreSQL, writes configuration, seeds the Flask app, installs Python dependencies, and creates systemd service `iptv-panel.service`.

6. **Service health check**
   - Immediately runs `systemctl status iptv-panel` to ensure Gunicorn is up.

7. **Stream provisioning permissions**
   - On the panel server (with `sudo`):
     - Creates `/root/.ssh/id_rsa` if missing.
     - Calls `ssh-copy-id` to push the public key to `root@95.217.193.163`.
     - Writes `/etc/sudoers.d/iptvpanel-user-manager` so the `iptvpanel` Unix user can run `/opt/user_manager.sh` without a password.
   - This step allows the panel to call the streaming server’s `/opt/user_manager.sh` script for token provisioning.

8. **SSL setup (optional but enabled in defaults)**
   - Executes `remote_ssl_setup.sh` on the panel server with the domain and email.
   - Stops Nginx/Gunicorn temporarily, runs Certbot in standalone mode, and writes `/opt/iptv-panel/config/nginx.conf`.
   - Restarts `iptv-panel` and Nginx so the panel is reachable at `https://panel.goalfete.com:54321/xui/`.

9. **Final message**
   - Indicates the URL to visit for the panel.  
   - If Certbot fails, the script automatically generates a self-signed certificate instead.

Logs on the panel server:

| Path                              | Purpose                               |
|-----------------------------------|---------------------------------------|
| `/opt/iptv-panel/installation.log` | Output captured from `pannel.sh`       |
| `/var/log/nginx/error.log`         | Nginx errors                           |
| `/opt/iptv-panel/logs/`           | Application logs                       |

---

## 5. Run the Deployment (from Workstation)

1. Open a local terminal in the project directory.
2. Run the script:
   ```bash
   ./deploy.sh
   ```
3. Type `y` when prompted (“Installer will COMPLETELY configure the remote server…”).
4. The script takes ~5–10 minutes depending on network and server speed.  
   It is fully automated—no more interaction is required if all prerequisites are satisfied.
5. Watch for the final line:
   ```
   >>> Done. Visit https://panel.goalfete.com:54321/xui/ to confirm the panel is up.
   ```

If the script exits early, scroll up to the last error message. Common issues are covered in Section 7.

---

## 6. Post-Deploy Checklist

1. **Login**
   - Open `https://panel.goalfete.com:54321/xui/`
   - Username: `admin`
   - Password: `GoldvisioN@1982` (change this immediately in the UI).

2. **Verify streaming integration**
   - Create a test user from the panel (`Users > Add User`).
   - The panel calls `/opt/user_manager.sh` on the streaming server to generate a password/token and pushes it into Redis.  
   - Verify the resulting M3U URL works: `https://stream.goalfete.com/get_playlist.php?token=...`

3. **API usage**
   - Programmatic user creation: `POST /api/users`
     ```
     curl -X POST https://panel.goalfete.com:54321/api/users \
       -H "Content-Type: application/json" \
       -d '{"username":"demo","password":"Test123456","plan_days":30,"max_connections":1}'
     ```
     Requires panel API authentication (implemented inside `local_panel/app.py`).

4. **Services**
   - `systemctl status iptv-panel`
   - `systemctl status nginx`

5. **Backups**
   - Use `/opt/iptv-panel/scripts/backup.sh` (creates compressed dumps).
   - Restore via `/opt/iptv-panel/scripts/restore.sh`.

---

## 7. Troubleshooting

| Symptom                                         | Fix                                                                                                  |
|-------------------------------------------------|-------------------------------------------------------------------------------------------------------|
| `ssh: connect to host ... port 22: Connection refused` | Open SSH on the streaming server (install `openssh-server`, ensure no firewall is blocking port 22). |
| Deploy stops at “Configuring stream provisioning permissions” | Fail2Ban banned the panel IP — unban via `fail2ban-client`, add it to `ignoreip` (see Section 3.2). |
| Certbot fails (no DNS, Cloudflare proxy on, etc.) | Ensure `panel.*` A record points directly to the panel IP, disable orange cloud, rerun `./deploy.sh`. |
| Nginx reload fails                               | Run `sudo nginx -t` on the panel server to inspect syntax; check `/opt/iptv-panel/config/nginx.conf`. |
| Invalid tokens when streaming                   | Confirm `/opt/user_manager.sh` on streaming server writes to Redis; check connectivity and tokens in DB. |
| Need to rerun deployment                        | The script is idempotent: re-running `./deploy.sh` wipes `/opt/iptv-panel` and redeploys cleanly.     |

To inspect the installation log:
```bash
ssh administrator@93.127.133.51
sudo tail -n 200 /opt/iptv-panel/installation.log
```

---

## 8. Maintenance Tips

- **Password management**: Change the admin password via the panel (`Settings > Admin Account`) and update `deploy.sh` if you want future runs to reuse it.
- **SSL renewal**: Certbot handles renewals. Check with `sudo certbot renew --dry-run`.
- **OS security**: Apply system updates regularly (`apt update && apt upgrade`).
- **Monitoring**: Consider installing `fail2ban-client status sshd` on both servers periodically to ensure no false positives.
- **Scaling**: For multiple streaming nodes, replicate the SSH key sharing and Redis token propagation on each server.

---

## 9. Quick Reference Commands

| Action                                  | Command                                                                      |
|-----------------------------------------|------------------------------------------------------------------------------|
| Redeploy the panel                      | `./deploy.sh`                                                                |
| Check Gunicorn service                  | `ssh administrator@93.127.133.51 "sudo systemctl status iptv-panel"`        |
| View panel logs                         | `ssh administrator@93.127.133.51 "sudo journalctl -u iptv-panel -f"`        |
| Check Nginx                             | `ssh administrator@93.127.133.51 "sudo systemctl status nginx"`             |
| Create user via API                     | `POST https://panel.goalfete.com:54321/api/users`                           |
| Create user from streaming server CLI   | `/opt/user_manager.sh create USERNAME DAYS`                                 |
| Inspect Redis token on streaming server | `redis-cli get token:<TOKEN>`                                               |

---

You now have everything required to take a brand-new environment from “no servers” to a production-ready IPTV panel with SSL, streaming integration, and API-driven user provisioning. Follow the steps carefully, and re-run `./deploy.sh` whenever you update the codebase or configuration templates. Happy streaming! 🎬

