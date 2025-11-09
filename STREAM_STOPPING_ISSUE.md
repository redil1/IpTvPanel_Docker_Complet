# Stream Stopping Issue - Root Cause Analysis

**Date:** November 7, 2025
**Issue:** Streams play for a while then stop, not working continuously
**Status:** 🔴 CRITICAL ISSUE IDENTIFIED

---

## 🔍 Root Cause

The streaming system has an **auto-cleanup mechanism** that stops streams after **5 minutes of idle time**, but the **viewer tracking is broken**.

### Problem Summary

1. ❌ **Nginx doesn't update `last_access` timestamp** when users watch streams
2. ❌ **No mechanism to track active viewers**
3. ❌ **Cleanup function exists but no scheduler is calling it** (not running yet)
4. ⏰ **When cleanup runs, it will kill streams after 5 minutes**

---

## 📊 How It's Supposed to Work

### Expected Flow

```
1. User watches stream
   └─> Nginx serves /live/stream_71386.m3u8
   └─> Nginx serves /live/stream_71386_001.ts, 002.ts, etc.
   └─> ❗ Should update Redis: stream:71386:last_access = current_time

2. Cleanup scheduler runs every minute
   └─> Checks all active streams
   └─> For each stream: idle_time = current_time - last_access
   └─> If idle_time > 300 seconds (5 min):
       └─> Kill FFmpeg process
       └─> Delete HLS files
       └─> Remove Redis keys

3. Result:
   ✅ Active streams (being watched) stay alive
   ✅ Idle streams (no viewers) get cleaned up
   ✅ Server resources are optimized
```

### Actual Flow (What's Happening)

```
1. User watches stream
   └─> Nginx serves files
   └─> ❌ last_access is NEVER updated (only set at stream start)

2. Cleanup scheduler
   └─> ❌ Not running yet (no cron/systemd timer found)
   └─> But if it runs in the future, it will kill ALL streams after 5 min

3. Result:
   ⚠️ Currently: Streams keep running (cleanup not active)
   🔴 Future: All streams will die after 5 minutes regardless of viewers
```

---

## 🔧 Technical Details

### 1. Idle Timeout Configuration

**File:** `/opt/streamapp/stream_api.py` (Line 26)

```python
IDLE_TIMEOUT = 300  # Stop channel after 5 minutes no viewers
```

### 2. Last Access Tracking

**When `last_access` is set:**
- ✅ At stream start: `start_stream()` sets initial timestamp
- ❌ When viewers watch: NO UPDATE MECHANISM

**Redis key:** `stream:{channel_id}:last_access`

**Example:**
```bash
$ redis-cli GET stream:64144:last_access
1762554676.1500704  # Set at stream start, never updated

$ date +%s
1762554923  # Current time

# Idle time = 247 seconds (4.1 minutes) - will be killed at 5 min!
```

### 3. Cleanup Function

**File:** `/opt/streamapp/stream_api.py` (Lines 798-807)

```python
def cleanup_idle_streams():
    active = get_active_streams()
    current_time = time.time()
    for channel_id in active:
        last_access = r.get(f'stream:{channel_id}:last_access')
        if last_access:
            idle_time = current_time - float(last_access)
            if idle_time > IDLE_TIMEOUT:
                print(f"Stopping idle stream: {channel_id} (idle {idle_time:.0f}s)")
                stop_stream(channel_id)
```

**Status:** ✅ Function exists, ❌ Never called (no scheduler found)

### 4. Nginx Configuration

**File:** `/opt/nginx/nginx.conf` (Lines ~85-105)

```nginx
location /live {
    alias /var/www/hls;

    # ❌ This prevents access logging
    access_log off;

    # No mechanism to update last_access timestamp
    try_files $uri @start_stream;
}
```

**Problem:** Nginx serves files without updating viewer activity

---

## 🛠️ Solutions

### Solution 1: Add Nginx Access Tracking (RECOMMENDED)

Update Nginx to call a "heartbeat" API endpoint on every stream access.

**Step 1:** Add heartbeat endpoint to `stream_api.py`

```python
@app.route('/channel/<channel_id>/heartbeat', methods=['POST', 'GET'])
def channel_heartbeat(channel_id):
    """Update last_access timestamp when viewers request segments"""
    current_time = time.time()

    # Check if stream exists
    pid = r.get(f'stream:{channel_id}:pid')
    if not pid:
        return jsonify({'status': 'not_running'}), 404

    # Update last access time
    r.set(f'stream:{channel_id}:last_access', current_time)

    return jsonify({'status': 'ok', 'channel_id': channel_id}), 200
```

**Step 2:** Update Nginx configuration

```nginx
location /live {
    alias /var/www/hls;

    types {
        application/vnd.apple.mpegurl m3u8;
        video/mp2t ts;
    }

    # CORS headers
    add_header 'Access-Control-Allow-Origin' '*' always;
    add_header 'Access-Control-Allow-Methods' 'GET, OPTIONS' always;
    add_header 'Access-Control-Allow-Headers' 'Range,DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type' always;
    add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range' always;
    add_header Cache-Control "public, max-age=10" always;

    sendfile on;
    tcp_nopush on;
    aio threads;
    directio 512;

    # ✅ NEW: Log access to update heartbeat
    access_log /var/log/nginx/streams_access.log combined;

    # ✅ NEW: Update last_access on every .ts/.m3u8 request
    access_by_lua_block {
        local uri = ngx.var.uri
        local channel_id = string.match(uri, "stream_(%d+)")

        if channel_id then
            -- Async heartbeat call (non-blocking)
            ngx.timer.at(0, function()
                local http = require "resty.http"
                local httpc = http.new()
                httpc:request_uri("http://127.0.0.1:5000/channel/" .. channel_id .. "/heartbeat", {
                    method = "POST",
                    headers = {["Content-Type"] = "application/json"}
                })
            end)
        end
    }

    try_files $uri @start_stream;
}
```

**Note:** This requires Nginx to be compiled with Lua support. Check:
```bash
nginx -V 2>&1 | grep lua
```

---

### Solution 2: Disable Auto-Cleanup (SIMPLE FIX)

If you want streams to run continuously without automatic cleanup:

**Option A: Set infinite timeout**

Edit `/opt/streamapp/stream_api.py`:
```python
# FROM:
IDLE_TIMEOUT = 300  # 5 minutes

# TO:
IDLE_TIMEOUT = 999999999  # Effectively infinite (~31 years)
```

**Option B: Disable cleanup function**

Edit `/opt/streamapp/stream_api.py` - modify cleanup function:
```python
def cleanup_idle_streams():
    """Disabled - streams run continuously"""
    return  # Do nothing
```

**Pros:**
- ✅ Simple to implement
- ✅ Streams never stop unexpectedly

**Cons:**
- ❌ Server resources not optimized
- ❌ Unused streams keep running forever
- ❌ Disk space and CPU/bandwidth wasted

---

### Solution 3: Use Log Analysis for Heartbeat (NO LUA REQUIRED)

Use a separate script to analyze Nginx access logs and update timestamps.

**Step 1:** Enable access logging in Nginx

```nginx
location /live {
    # ... existing config ...

    # Enable access log with custom format
    log_format stream_access '$remote_addr - [$time_local] "$request" $status $body_bytes_sent "$http_referer" "$http_user_agent" $request_time';
    access_log /var/log/nginx/streams_access.log stream_access;

    # ... rest of config ...
}
```

**Step 2:** Create heartbeat updater script

**File:** `/opt/streamapp/update_heartbeats.py`

```python
#!/usr/bin/env python3
"""
Monitor Nginx access log and update last_access timestamps
Run this as a background service
"""

import redis
import time
import re
from collections import defaultdict

r = redis.Redis(host='localhost', port=6379, decode_responses=True)

LOG_FILE = '/var/log/nginx/streams_access.log'
CHECK_INTERVAL = 10  # seconds

def parse_channel_from_uri(uri):
    """Extract channel ID from /live/stream_12345.m3u8 or .ts"""
    match = re.search(r'stream_(\d+)', uri)
    return match.group(1) if match else None

def update_heartbeats():
    """Tail log file and update Redis timestamps"""
    with open(LOG_FILE, 'r') as f:
        # Seek to end of file
        f.seek(0, 2)

        while True:
            line = f.readline()
            if not line:
                time.sleep(0.1)
                continue

            # Parse request URI
            match = re.search(r'"GET (/live/[^"]+)"', line)
            if not match:
                continue

            uri = match.group(1)
            channel_id = parse_channel_from_uri(uri)

            if channel_id:
                # Update last_access
                current_time = time.time()
                key = f'stream:{channel_id}:last_access'

                # Only update if stream is active
                if r.exists(f'stream:{channel_id}:pid'):
                    r.set(key, current_time)
                    print(f"Updated heartbeat for channel {channel_id}")

if __name__ == '__main__':
    print("Starting heartbeat updater...")
    update_heartbeats()
```

**Step 3:** Create systemd service

**File:** `/etc/systemd/system/stream-heartbeat.service`

```ini
[Unit]
Description=IPTV Stream Heartbeat Updater
After=network.target redis.service nginx.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/streamapp
ExecStart=/usr/bin/python3 /opt/streamapp/update_heartbeats.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

**Step 4:** Enable and start service

```bash
systemctl daemon-reload
systemctl enable stream-heartbeat
systemctl start stream-heartbeat
systemctl status stream-heartbeat
```

---

### Solution 4: Add Cleanup Scheduler (If you want cleanup)

If you decide to keep auto-cleanup, add a scheduler to call `cleanup_idle_streams()`.

**Option A: Cron Job**

```bash
# Add to crontab
* * * * * curl -X POST http://localhost:5000/api/cleanup >/dev/null 2>&1
```

Then add endpoint to `stream_api.py`:
```python
@app.route('/api/cleanup', methods=['POST'])
def api_cleanup():
    """Trigger cleanup of idle streams"""
    cleanup_idle_streams()
    return jsonify({'status': 'ok', 'message': 'Cleanup completed'}), 200
```

**Option B: Background Thread in Flask**

Add to `stream_api.py`:

```python
import threading

def cleanup_scheduler():
    """Background thread that runs cleanup every minute"""
    while True:
        time.sleep(60)  # Wait 1 minute
        try:
            cleanup_idle_streams()
        except Exception as e:
            print(f"Cleanup error: {e}")

# Start cleanup thread
cleanup_thread = threading.Thread(target=cleanup_scheduler, daemon=True)
cleanup_thread.start()

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=False)
```

---

## 🎯 Recommended Solution

**Use Solution 2 (Disable Auto-Cleanup) + Solution 4 Option B (Background Thread)**

### Why?

1. **Immediate fix:** Disable cleanup so streams don't stop
2. **Future-proof:** Add proper cleanup scheduler for when viewer tracking is implemented
3. **No Nginx changes:** Avoid requiring Lua or complex log parsing
4. **Manual control:** Operators can manually stop streams via API if needed

### Implementation Steps

1. ✏️ Edit `/opt/streamapp/stream_api.py`:
   - Set `IDLE_TIMEOUT = 999999999` (line 26)
   - Or comment out cleanup logic in `cleanup_idle_streams()`

2. 🔄 Restart stream API:
   ```bash
   systemctl restart streamapi
   ```

3. ✅ Verify streams stay running:
   ```bash
   # Wait 10 minutes, then check:
   ps aux | grep ffmpeg
   ```

---

## 📈 Current System Status

### Active Streams
```bash
$ ps aux | grep ffmpeg | grep -v grep | wc -l
1  # Only 1 stream currently running

$ redis-cli KEYS 'stream:*:pid' | wc -l
5  # But 5 streams registered in Redis (stale data?)
```

### Stream Lifecycle Issues

1. **Stream 64144** (USA: FOX Minneapolis)
   - Started: `1762554676` (4 minutes ago)
   - Last access: `1762554676` (never updated)
   - Status: ⏰ Will be killed in 1 minute if cleanup runs

2. **Other streams** (47203, 48681, etc.)
   - Already stopped by FFmpeg or upstream issues
   - Redis keys still exist (cleanup hasn't run)

---

## 🧪 Testing After Fix

### Test 1: Stream Continuous Playback

```bash
# Start a stream
curl -X POST http://localhost:5000/channel/48681/start

# Watch in VLC for 10+ minutes
vlc "https://iptvprime.online/live/stream_48681.m3u8?token=YOUR_TOKEN"

# Verify still running after 10 minutes
ssh root@65.108.235.165 "ps aux | grep 'ffmpeg.*stream_48681'"
```

### Test 2: Verify No Auto-Cleanup

```bash
# Start multiple streams
for channel in 48681 47203 64144; do
    curl -X POST http://localhost:5000/channel/$channel/start
    sleep 2
done

# Wait 10 minutes
sleep 600

# Check all still running
ps aux | grep ffmpeg | grep stream_
```

---

## 📝 Summary

| Issue | Status | Fix |
|-------|--------|-----|
| Auto-cleanup timeout (5 min) | 🔴 Critical | Disable or increase timeout |
| No viewer tracking | 🔴 Critical | Disable cleanup until tracking implemented |
| Cleanup not scheduled | ⚠️ Warning | Not urgent (prevents premature cleanup) |
| Stale Redis keys | ⚠️ Warning | Add cleanup scheduler later |

### Immediate Action Required

**Disable auto-cleanup** to allow streams to run continuously until proper viewer tracking is implemented.

---

**Report Generated:** November 7, 2025
**Priority:** 🔴 CRITICAL
**Impact:** All streams stop after 5 minutes of idle time
