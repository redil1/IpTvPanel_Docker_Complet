# IPTV Panel – Initial Configuration Guide

Once the production installer finishes (`./deploy.sh`), the panel is reachable at `http://<your-panel-ip>:54321/xui/`.
Log in with the admin credentials you supplied during deployment (default user: `admin`).

## 1. Initial Setup Wizard
The first login launches a guided three-step wizard mirroring the XUI onboarding flow:

### Step 1 – Server Settings
```
Server Name: Main Panel (or your preferred label)
Time Zone: Choose your timezone (e.g. UTC)
Language: English
```

### Step 2 – Streaming Server
```
Server Name: Hetzner-Stream-01
Server IP: <your Hetzner origin>
Server Port: 80
Server Type: Load Balancer
Protocol: HTTP
Status: Active
```

These values are stored in `Settings` and the streaming server config JSON for later reference.

### Step 3 – M3U Configuration
```
M3U URL Format:
http://stream.myiptv.com/live/stream_{CHANNEL_ID}.m3u8?token={TOKEN}

Token Type: User Token (default)
Token Length: 32
```

The token length influences user token generation; the format controls playlist entries.

## 2. Global Settings
Navigate to **Settings** (top navigation bar):
- **Stream Domain** – set this to the Cloudflare/edge hostname (e.g. `stream.myiptv.com`).  
  This value drives playlist URLs and Cloudflare purges.
- **Streaming Server IP** – the Hetzner origin IP (e.g. `95.217.193.163`).  
- **Default Subscription Days / Max Connections** – defaults used when adding users.  
- Save changes; the system logs the action in **System Logs**.

> _Note:_ Time zone and language are managed at the OS level (Ubuntu) and by your browser.  
> They are not panel-specific settings in this release.

## 3. Streaming Server Integration
After the wizard, user/channel changes continue to sync with the Hetzner API using the `.env` values:

```
STREAMING_API_BASE_URL=https://stream.example.com/api
STREAMING_API_TOKEN=<token>
```

Ensure these fields were populated during installation (they can be edited in `/opt/iptv-panel/.env`).  
The service module `services/streaming.py` will create/update/delete users and channels automatically.

## 4. M3U / Playlist Format
User pages show the playlist URL (still `http://<stream_domain>/playlist/<TOKEN>.m3u8`), while the entries inside the playlist use the format you saved in the wizard:

```
http://<stream_domain>/playlist/<USER_TOKEN>.m3u8
```

- Playlist lines follow your template (e.g. `http://stream.myiptv.com/live/stream_{CHANNEL_ID}.m3u8?token={TOKEN}` → resolved with actual channel/tokens).
- Token length respects the wizard setting (default 32). Reset via **Reset Token** on the user page.

No manual “M3U Settings” screen is required—links are generated automatically using the values from **Settings**.

## 5. Adding the Streaming Origin
To wire in your streaming server metadata:

1. Go to **Channels → Add Channel**.
2. Provide:
   - **Channel ID** (e.g. `sports_hd`)
   - **Name** and **Category**
   - **Source URL** pointing to the Hetzner/Nginx origin (e.g. `http://95.217.193.163/live/sports_hd.m3u8`)
3. On save, the panel syncs the channel definition to the streaming API and purges Cloudflare caches.


## 6. Creating a Test User
1. Navigate to **Users → Add User**.
2. Fill in:
   - Username (`testuser`)
   - Password (`Test123456`)
   - Email (optional)
   - Subscription days (`30`)
   - Max connections (`2`)
3. Save. The panel:
   - Generates a token using your configured token length (`User → View` page shows it)
   - Syncs the user to Hetzner
   - Purges Cloudflare caches for the new playlist

### Playlist access example

```
http://stream.myiptv.com/playlist/<generated_token>.m3u8
```

## 7. Cloudflare Integration
If you provided `CLOUDFLARE_ZONE_ID` and `CLOUDFLARE_API_TOKEN`, the panel automatically purges:
- `playlist/<token>.m3u8` whenever user tokens change.
- `live/stream_<CHANNEL_ID>.m3u8` when channels are created/updated/deleted.

These callouts are logged in **System Logs** with category `CLOUDFLARE`.

## 8. Service Validation
After initial configuration, verify:

```bash
ssh administrator@<panel-ip>
echo '<sudo-password>' | sudo -S systemctl status iptv-panel --no-pager
```

Also check `/opt/iptv-panel/logs/` for runtime logs and `/opt/iptv-panel/backups/` for daily dumps if you run the backup script.

## 9. HTTPS / SSL (automated optional)
If you set `PANEL_DOMAIN` and `CERTBOT_EMAIL` in `deploy.sh` before running the installer, the deploy script will:

1. Install Certbot
2. Issue a Let’s Encrypt certificate for `PANEL_DOMAIN`
3. Rewrite Nginx to terminate TLS on ports 443/54321
4. Reload the services so the panel is reachable at `https://PANEL_DOMAIN:54321/xui/`

You can reissue manually later by running `sudo certbot renew --dry-run` and reloading Nginx.

---

This workflow mirrors the functionality of commercial panels (e.g., Xtream UI) while matching the actual features available in this IPTV Panel project.
