# IPTV Streaming Server Architecture Documentation

**Server:** 65.108.235.165 (Hetzner)
**OS:** Ubuntu 22.04 LTS
**Domain:** iptvprime.online
**Purpose:** High-performance on-demand IPTV streaming with FFmpeg transcoding

---

## 🏗️ Architecture Overview

The streaming server operates as an **on-demand transcoding proxy** that:
1. Receives playlist requests from authenticated users
2. Starts FFmpeg streams on-demand when requested
3. Transcodes/proxies upstream IPTV sources to HLS format
4. Serves HLS segments via Nginx with Cloudflare CDN
5. Manages stream lifecycle (start/stop/cleanup)

---

## 📦 Component Stack

| Component | Version | Purpose | Port/Path |
|-----------|---------|---------|-----------|
| **Nginx** | Custom build with RTMP | HTTP server, HLS delivery, reverse proxy | 80 (HTTP) |
| **Redis** | 6.0.16 | User/token storage, channel metadata | 6379 (localhost) |
| **Flask API** | Python 3 | Stream management, user/channel API | 5000 (localhost) |
| **FFmpeg** | Latest | On-demand stream transcoding | N/A (spawned processes) |
| **PHP-FPM** | 8.1 | M3U playlist generation | Unix socket |
| **CloudScraper** | Python lib | Bypass upstream protections | N/A |

---

## 🔧 Core Services

### 1. Stream Management API (`stream_api.py`)

**Service:** `streamapi.service`
**Port:** 5000 (internal only)
**Path:** `/opt/streamapp/stream_api.py`

#### Key Endpoints

| Endpoint | Method | Auth | Purpose |
|----------|--------|------|---------|
| `/api/users` | GET | Bearer | List all users |
| `/api/users` | POST | Bearer | Create user + store in Redis |
| `/api/users/<username>` | GET/PUT/DELETE | Bearer | Manage user |
| `/api/channels` | GET | Bearer | List all channels |
| `/api/channels` | POST | Bearer | Create channel + update channels.txt |
| `/api/channels/<id>` | PUT/DELETE | Bearer | Manage channel |
| `/api/stream/start` | POST | None | Start FFmpeg stream |
| `/api/stream/stop` | POST | None | Stop FFmpeg stream |
| `/api/streams/active` | GET | None | List running streams |
| `/api/stats` | GET | None | Server statistics |

#### User/Channel Synchronization

When panel server calls `/api/users POST`:
```json
{
  "username": "john123",
  "token": "64_char_hex_token",
  "email": "john@example.com",
  "expires_at": "2025-12-07T21:50:51.244826Z",
  "max_connections": 2,
  "is_active": true,
  "password": "secret"
}
```

**Redis Storage:**
```
SET user:john123 → Full JSON payload
SET token:64_char_hex_token → {"username":"john123","expires_at":"...","max_connections":2,...}
SADD users:all → john123
```

**Token TTL:** Automatically calculated from `expires_at` and set via `SETEX`

### 2. Nginx HTTP/RTMP Server

**Service:** `nginx.service`
**Config:** `/opt/nginx/nginx.conf`
**Binary:** `/opt/nginx/sbin/nginx`
**Workers:** 12 (auto-scaled)

#### Configuration Highlights

```nginx
worker_processes auto;          # CPU cores
worker_connections 10000;       # 10K concurrent connections per worker
keepalive_timeout 65;
```

#### Key Locations

**HLS Delivery** (`/live/*`)
```nginx
location /live {
    alias /var/www/hls;

    # M3U8/TS file serving
    types {
        application/vnd.apple.mpegurl m3u8;
        video/mp2t ts;
    }

    # CORS headers for cross-origin playback
    add_header 'Access-Control-Allow-Origin' '*' always;
    add_header Cache-Control "public, max-age=10" always;

    # Performance optimizations
    sendfile on;
    tcp_nopush on;
    aio threads;
    directio 512;
    access_log off;  # No logging for performance

    # Fallback to stream starter if file doesn't exist
    try_files $uri @start_stream;
}
```

**Stream Auto-Start** (`@start_stream`)
```nginx
location @start_stream {
    internal;

    # Extract channel ID from URL
    set $channel_id "";
    if ($uri ~* "^/live/stream_(\d+)\.m3u8$") {
        set $channel_id $1;
    }

    # Proxy to Flask API to start stream
    proxy_pass http://127.0.0.1:5001/channel/$channel_id/start;
}
```

**Cloudflare Integration**
```nginx
# Cloudflare IP ranges for real_ip detection
set_real_ip_from 173.245.48.0/20;
set_real_ip_from 103.21.244.0/22;
# ... 10+ more ranges
real_ip_header CF-Connecting-IP;
```

**PHP Playlist Delivery**
```nginx
location ~ \.php$ {
    root /var/www/playlists;
    fastcgi_pass unix:/run/php/php8.1-fpm.sock;
    fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    include fastcgi_params;
}
```

**RTMP Server** (Currently configured but unused)
```nginx
rtmp {
    server {
        listen 1935;
        application live {
            live on;
            record off;
            allow publish 127.0.0.1;
            deny publish all;
        }
    }
}
```

### 3. Redis Database

**Service:** `redis-server.service`
**Port:** 6379 (localhost only)
**Memory:** 2.36M used
**Commands Processed:** 397,281

#### Data Structure

**User Tokens:**
```
token:87f3b8f5238f... → {
  "username": "test_user_migration_final",
  "token": "87f3b8f5238f...",
  "expires_at": "2026-01-06T21:50:51.244826Z",
  "is_active": true,
  "max_connections": 3,
  "email": "testmigration@example.com",
  "password": "2D9phJKJz8TPM37"
}
```

**User Records:**
```
user:test_user_migration_final → Full user payload JSON
```

**Channel Records:**
```
channel:48681 → {
  "channel_id": "48681",
  "name": "MBC Pro aflam",
  "source_url": "http://s.showplustv.pro:80/live/user.../48681.ts",
  "logo": "images/no_logo.jpg",
  "category": "Favorite",
  "quality": "medium",
  "order": 1,
  "category_order": 1,
  "is_active": true
}
```

**Index Sets:**
```
users:all → SADD of all usernames
channels:all → SADD of all channel IDs
```

**Stream Metadata:**
```
stream:48681:pid → 12345
stream:48681:started → 1699378912.123
stream:48681:source → http://upstream.com/channel.ts
stream:48681:last_access → 1699379012.456
```

### 4. Playlist Generation (`get_playlist.php`)

**Path:** `/var/www/playlists/get_playlist.php`
**URL:** `http://iptvprime.online/get_playlist.php?token=USER_TOKEN`

#### Workflow

1. **Receive Request**
   ```
   GET /get_playlist.php?token=87f3b8f5238f1bbd478c870f02a4977a074c860db1ff47c2bebce276d3624651
   ```

2. **Validate Token** (Redis lookup)
   ```php
   $user_data = $redis->get("token:$token");
   // Check is_active, expires_at
   ```

3. **Generate M3U8 Playlist**
   ```php
   echo "#EXTM3U\n";

   $channel_ids = $redis->sMembers('channels:all');
   foreach ($channel_ids as $channel_id) {
       $channel = json_decode($redis->get("channel:$channel_id"), true);

       echo '#EXTINF:-1 ';
       echo 'tvg-id="' . $channel['id'] . '" ';
       echo 'tvg-name="' . $channel['name'] . '" ';
       echo 'tvg-logo="' . $channel['logo'] . '" ';
       echo 'group-title="' . $channel['category'] . '",';
       echo $channel['name'] . "\n";

       echo 'http://iptvprime.online/live/stream_' . $channel['id'] . '.m3u8?token=' . $token . "\n";
   }
   ```

4. **Output Example**
   ```m3u8
   #EXTM3U
   #EXTINF:-1 tvg-id="48681" tvg-name="MBC Pro aflam" tvg-logo="images/no_logo.jpg" group-title="Favorite",MBC Pro aflam
   http://iptvprime.online/live/stream_48681.m3u8?token=87f3b8f5238f...
   #EXTINF:-1 tvg-id="87827" tvg-name="beIN SPORT Very Low 1" tvg-logo="..." group-title="BeIN Sports Very LQ",beIN SPORT Very Low 1
   http://iptvprime.online/live/stream_87827.m3u8?token=87f3b8f5238f...
   ```

---

## 🎬 Stream Lifecycle

### On-Demand Streaming Flow

```
┌──────────────┐
│  User Opens  │
│  M3U Player  │
└──────┬───────┘
       │
       │ 1. Load playlist
       ▼
┌─────────────────────────────────────┐
│ http://iptvprime.online/           │
│ get_playlist.php?token=XXX          │
└──────┬──────────────────────────────┘
       │
       │ 2. PHP validates token via Redis
       │    generates M3U8 with channel URLs
       ▼
┌─────────────────────────────────────┐
│ http://iptvprime.online/live/      │
│ stream_48681.m3u8?token=XXX         │
└──────┬──────────────────────────────┘
       │
       │ 3. Nginx try_files → file not found
       │    triggers @start_stream fallback
       ▼
┌─────────────────────────────────────┐
│ @start_stream (internal redirect)   │
│ proxy_pass to stream_api.py         │
└──────┬──────────────────────────────┘
       │
       │ 4. POST /channel/48681/start
       ▼
┌─────────────────────────────────────┐
│ stream_api.py start_stream()        │
│ - Load channel from Redis           │
│ - Extract source_url                │
│ - Use CloudScraper + proxy          │
│ - Spawn FFmpeg process              │
└──────┬──────────────────────────────┘
       │
       │ 5. FFmpeg transcodes to HLS
       ▼
┌─────────────────────────────────────┐
│ /var/www/hls/                       │
│ ├── stream_48681.m3u8               │
│ ├── stream_48681_001.ts             │
│ ├── stream_48681_002.ts             │
│ └── stream_48681_003.ts             │
└──────┬──────────────────────────────┘
       │
       │ 6. Nginx serves HLS files
       │    Cloudflare caches segments
       ▼
┌─────────────────────────────────────┐
│ User's media player receives        │
│ transcoded HLS stream               │
└─────────────────────────────────────┘
```

### FFmpeg Command Structure

**Attempt 1: Stream Copy (Fast, No Transcoding)**
```bash
/usr/bin/ffmpeg \
  -reconnect 1 \
  -reconnect_streamed 1 \
  -reconnect_delay_max 5 \
  -rw_timeout 15000000 \
  -probesize 5M \
  -analyzeduration 5M \
  -user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64)..." \
  -headers "User-Agent: ...\r\nOrigin: ...\r\nReferer: ...\r\nCookie: ...\r\n" \
  -i "http://s.showplustv.pro:80/live/user11a617ef/pass6278ce42c7e9/48681.ts" \
  -c copy \
  -bufsize 4096k \
  -max_muxing_queue_size 1024 \
  -f hls \
  -hls_time 4 \
  -hls_list_size 6 \
  -hls_flags delete_segments+append_list+split_by_time \
  -hls_playlist_type event \
  -hls_segment_filename "/var/www/hls/stream_48681_%03d.ts" \
  "/var/www/hls/stream_48681.m3u8"
```

**Attempt 2: Transcode (Fallback if copy fails)**
```bash
# Same input args...
  -c:v libx264 -preset veryfast -tune zerolatency \
  -b:v 1500k -maxrate 1500k -bufsize 3000k \
  -s 854x480 -g 48 -keyint_min 48 -sc_threshold 0 \
  -c:a aac -b:a 96k -ar 48000 \
  # Same HLS output args...
```

**Quality Presets:**
| Quality | Resolution | Video Bitrate | Audio Bitrate |
|---------|------------|---------------|---------------|
| Low | 640x360 | 1000k | 64k |
| Medium | 854x480 | 1500k | 96k |
| High | 1280x720 | 2500k | 128k |

### Stream Management

**Active Stream Tracking:**
```python
# Redis keys set when stream starts
r.set(f'stream:{channel_id}:pid', ffmpeg_proc.pid)
r.set(f'stream:{channel_id}:started', time.time())
r.set(f'stream:{channel_id}:source', source_url)
r.set(f'stream:{channel_id}:resolved_source', resolved_url)
r.set(f'stream:{channel_id}:last_access', time.time())
```

**Idle Stream Cleanup:**
```python
IDLE_TIMEOUT = 300  # 5 minutes

def cleanup_idle_streams():
    active = get_active_streams()
    current_time = time.time()
    for channel_id in active:
        last_access = r.get(f'stream:{channel_id}:last_access')
        if last_access:
            idle_time = current_time - float(last_access)
            if idle_time > IDLE_TIMEOUT:
                print(f"Stopping idle stream: {channel_id}")
                stop_stream(channel_id)  # SIGTERM to FFmpeg
```

**Stream Stop:**
```python
def stop_stream(channel_id):
    pid = r.get(f'stream:{channel_id}:pid')
    os.kill(int(pid), signal.SIGTERM)

    # Delete HLS files
    for f in os.listdir(HLS_DIR):
        if f.startswith(f'stream_{channel_id}'):
            os.remove(os.path.join(HLS_DIR, f))

    # Clean Redis
    r.delete(f"stream:{channel_id}:pid",
             f"stream:{channel_id}:started",
             f"stream:{channel_id}:source",
             f"stream:{channel_id}:resolved_source",
             f"stream:{channel_id}:last_access")
```

---

## 📂 Directory Structure

```
/opt/streamapp/
├── stream_api.py           # Main Flask API
├── channel_loader.py       # Background channel sync
├── channels.txt            # Channel database (pipe-delimited)
├── requirements.txt        # Python dependencies
├── venv/                   # Python virtual environment
└── stream_api.log          # API logs

/var/www/hls/              # HLS output directory
├── stream_48681.m3u8      # Channel playlist
├── stream_48681_001.ts    # Video segment
├── stream_48681_002.ts
└── ...

/var/www/playlists/
└── get_playlist.php       # M3U playlist generator

/opt/nginx/
├── nginx.conf             # Main Nginx configuration
├── sbin/nginx             # Nginx binary
└── mime.types             # MIME type definitions
```

---

## 🔐 Security & Access Control

### Token Validation Flow

1. **User requests playlist:**
   ```
   GET /get_playlist.php?token=87f3b8f5238f...
   ```

2. **PHP checks Redis:**
   ```php
   $user_data = $redis->get("token:87f3b8f5238f...");
   $decoded = json_decode($user_data, true);

   // Check active status
   if (!$decoded['is_active']) {
       die("ERROR: Token disabled");
   }

   // Check expiry
   if (strtotime($decoded['expires_at']) < time()) {
       die("ERROR: Token expired");
   }
   ```

3. **Stream URL includes token:**
   ```
   http://iptvprime.online/live/stream_48681.m3u8?token=87f3b8f5238f...
   ```

4. **Nginx serves without additional auth** (security relies on token secrecy + Cloudflare protection)

### API Authentication

**Streaming API** (`stream_api.py`)
```python
@require_admin_token
def api_create_user():
    # Bearer token in Authorization header
    auth = request.headers.get('Authorization')
    token = auth.split('Bearer ')[-1]

    if token != ADMIN_API_TOKEN:
        return jsonify({'error': 'Unauthorized'}), 401
```

**Panel → Streaming Sync**
```python
# Panel server sends:
headers = {
    'Authorization': f'Bearer {STREAMING_API_TOKEN}',
    'Content-Type': 'application/json'
}
response = requests.post('http://65.108.235.165:5000/api/users',
                        headers=headers, json=user_payload)
```

---

## 🌐 CDN Integration (Cloudflare)

### Configuration

1. **DNS:**
   ```
   iptvprime.online → CNAME → Cloudflare proxy
   Cloudflare → Origin: 65.108.235.165:80
   ```

2. **Cloudflare Settings:**
   - Proxy Status: ✅ Proxied (orange cloud)
   - SSL/TLS: Full (strict)
   - Caching: Aggressive for `.m3u8` and `.ts` files

3. **Nginx Real IP Detection:**
   ```nginx
   set_real_ip_from 173.245.48.0/20;  # Cloudflare IP ranges
   real_ip_header CF-Connecting-IP;    # Get real user IP
   ```

4. **Cache Purging:**
   - Panel server purges Cloudflare cache on user/channel changes
   - Uses Cloudflare API to purge specific URLs:
     ```
     https://stream.domain/playlist/{TOKEN}.m3u8
     https://stream.domain/live/stream_{CHANNEL_ID}.m3u8
     ```

---

## 📊 Performance Characteristics

### Server Resources

```
CPU: AMD EPYC (auto-scaled workers)
RAM: 76GB total, ~2.36M Redis usage
Disk: HLS segments auto-deleted on stream stop
Network: Hetzner high-bandwidth
```

### Nginx Tuning

```nginx
worker_processes auto;              # 12 workers (CPU cores)
worker_rlimit_nofile 100000;        # 100K file descriptors
worker_connections 10000;           # 10K connections per worker
                                    # = 120K total concurrent connections

keepalive_timeout 65;
keepalive_requests 1000;            # Reduce connection overhead
reset_timedout_connection on;
client_body_timeout 10;
send_timeout 10;

# Zero-copy file transfers
sendfile on;
tcp_nopush on;
tcp_nodelay on;
aio threads;                        # Asynchronous I/O
directio 512;                       # Direct I/O for large files

access_log off;                     # No logging for /live (performance)
```

### Gzip Compression

```nginx
gzip on;
gzip_comp_level 6;
gzip_types text/plain text/css application/json
           application/javascript application/vnd.apple.mpegurl;
```

### HLS Segment Settings

```
-hls_time 4                # 4-second segments (low latency)
-hls_list_size 6           # Keep 6 segments = 24 seconds buffer
-hls_flags delete_segments # Auto-cleanup old segments
-hls_playlist_type event   # Event playlist (not VOD)
```

---

## 🔄 Panel → Streaming Server Integration

### User Synchronization

**Panel Server** (`93.127.133.51`) **→** **Streaming Server** (`65.108.235.165`)

```python
# Panel: /opt/streamapp/IptvPannel/local_panel/services/streaming.py
class StreamingService:
    BASE_URL = "http://65.108.235.165:5000"
    TOKEN = "c4db08c06f1b28356fe90edb687dca23269241662779b778f9dce5ee3150c340"

    @staticmethod
    def sync_user(user, action):  # action: create|update|delete
        headers = {
            'Authorization': f'Bearer {TOKEN}',
            'Content-Type': 'application/json'
        }

        if action == 'create':
            payload = {
                'username': user.username,
                'token': user.token,
                'email': user.email,
                'expires_at': user.expiry_date.isoformat() + 'Z',
                'max_connections': user.max_connections,
                'is_active': user.is_active,
                'password': user.password
            }
            response = requests.post(f'{BASE_URL}/api/users',
                                    headers=headers, json=payload)

        elif action == 'update':
            response = requests.put(f'{BASE_URL}/api/users/{user.username}',
                                   headers=headers, json=payload)

        elif action == 'delete':
            response = requests.delete(f'{BASE_URL}/api/users/{user.username}',
                                      headers=headers)
```

### Channel Synchronization

**Same pattern for channels:**
```python
StreamingService.sync_channel(channel, 'create')
# → POST http://65.108.235.165:5000/api/channels
# → Updates Redis + regenerates channels.txt
```

---

## 🛠️ Operational Commands

### Service Management

```bash
# Check service status
systemctl status nginx
systemctl status redis-server
systemctl status streamapi

# Restart services
systemctl restart nginx
systemctl restart streamapi

# View logs
journalctl -u streamapi -f
tail -f /var/log/nginx/error.log
```

### Redis Operations

```bash
# Connect to Redis
redis-cli

# List all tokens
KEYS token:*

# Get user data
GET "token:87f3b8f5238f1bbd478c870f02a4977a074c860db1ff47c2bebce276d3624651"

# List all users
SMEMBERS users:all

# List all channels
SMEMBERS channels:all

# Check stream metadata
GET stream:48681:pid
GET stream:48681:started
```

### Stream Monitoring

```bash
# Check active FFmpeg processes
ps aux | grep ffmpeg

# List HLS files
ls -lh /var/www/hls/

# Stop all streams
killall ffmpeg

# Check active streams via API
curl http://localhost:5000/api/streams/active

# Server stats
curl http://localhost:5000/api/stats
```

---

## 🐛 Troubleshooting

### Common Issues

**1. Stream won't start**
```bash
# Check source URL accessibility
curl -I "http://s.showplustv.pro:80/live/user11a617ef/pass6278ce42c7e9/48681.ts"

# Check FFmpeg manually
ffmpeg -i "SOURCE_URL" -c copy test.m3u8

# Check logs
journalctl -u streamapi -n 100
```

**2. Token validation fails**
```bash
# Check Redis
redis-cli GET "token:XXXXX"

# Check PHP errors
tail -f /var/log/nginx/error.log
tail -f /var/log/php8.1-fpm.log
```

**3. Zombie FFmpeg processes**
```python
# Fixed in stream_api.py with self-healing:
if proc.status() == psutil.STATUS_ZOMBIE:
    print(f"⚠️ Stale PID {pid}, restarting...")
    r.delete(f"stream:{channel_id}:*")
```

**4. High CPU usage**
```bash
# Check running streams
curl http://localhost:5000/api/streams/active

# Stop idle streams manually
curl -X POST http://localhost:5000/api/stream/stop \
  -H "Content-Type: application/json" \
  -d '{"channel_id":"48681"}'
```

---

## 📈 Monitoring & Analytics

### API Endpoints

```bash
# Health check
curl http://localhost:5000/api/health
# {"status": "ok", "timestamp": 1699379012.123}

# Server stats
curl http://localhost:5000/api/stats
# {
#   "cpu_percent": 15.2,
#   "memory_percent": 12.5,
#   "memory_used_gb": 9.6,
#   "disk_percent": 45.1,
#   "network_sent_gb": 124.3,
#   "network_recv_gb": 89.2,
#   "active_streams": 3,
#   "uptime_hours": 120.5
# }

# Active streams
curl http://localhost:5000/api/streams/active
# {
#   "streams": {
#     "48681": {"pid": 12345, "started": "1699378912.123"},
#     "87827": {"pid": 12346, "started": "1699378950.456"}
#   },
#   "count": 2
# }
```

---

## 🚀 Summary

The streaming server is a **high-performance, on-demand IPTV transcoding proxy** that:

✅ **Validates users** via Redis token storage
✅ **Generates M3U playlists** dynamically via PHP
✅ **Starts FFmpeg streams** on-demand when users watch channels
✅ **Transcodes to HLS** for universal compatibility
✅ **Serves via Nginx** with Cloudflare CDN caching
✅ **Auto-stops idle streams** after 5 minutes
✅ **Syncs with panel server** via REST API
✅ **Handles 120K+ concurrent connections** via tuned Nginx

**Key Strengths:**
- 🔥 On-demand streaming (no wasted resources)
- ⚡ Fast startup with stream copy mode
- 🛡️ CloudScraper bypasses upstream protections
- 🌐 Cloudflare CDN reduces origin load
- 🧠 Self-healing zombie process detection
- 📊 Real-time monitoring and stats

This architecture efficiently handles large-scale IPTV delivery with minimal resource waste through intelligent on-demand stream management.

---

**Last Updated:** November 7, 2025
**Documentation By:** Claude Code
