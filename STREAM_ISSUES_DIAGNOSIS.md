# Stream Playback Issues - Diagnosis Report

**Date:** November 7, 2025
**Tested URL:** `http://iptvprime.online/live/stream_71386.m3u8?token=50e0113420874a1f6decbbf539753cab486f3ee150f177450429218697b040a4`
**Result:** ❌ No video playback in VLC

---

## 🔍 Root Cause Analysis

### Issue #1: ❌ **Nginx Port Misconfiguration**

**Problem:** Nginx @start_stream is proxying to wrong port

**Current Configuration** (`/opt/nginx/nginx.conf`):
```nginx
location @start_stream {
    ...
    proxy_pass http://127.0.0.1:5001/channel/$channel_id/start;
    #                              ^^^^
    #                            WRONG PORT!
}
```

**Actual Stream API Port:** `5000` (not 5001)

**Evidence:**
```bash
$ systemctl status streamapi
# stream_api.py running on port 5000

$ netstat -tlnp | grep 5000
tcp  0.0.0.0:5000  LISTEN  53785/python3

$ netstat -tlnp | grep 5001
# No process listening on 5001
```

**Impact:** When a user requests a stream that doesn't exist yet, Nginx tries to auto-start it but fails because it's calling the wrong port.

**Fix Required:**
```nginx
# Change from:
proxy_pass http://127.0.0.1:5001/channel/$channel_id/start;

# To:
proxy_pass http://127.0.0.1:5000/channel/$channel_id/start;
```

---

### Issue #2: ⚠️ **Missing /channel/<id>/start Endpoint**

**Problem:** The stream API doesn't have a `/channel/<id>/start` route

**Current Routes in stream_api.py:**
```python
@app.route('/api/stream/start', methods=['POST'])   # ✅ EXISTS
@app.route('/api/stream/stop', methods=['POST'])    # ✅ EXISTS
@app.route('/api/streams/active', methods=['GET'])  # ✅ EXISTS

# ❌ MISSING: /channel/<channel_id>/start
```

**What Nginx expects:**
```
POST /channel/71386/start
```

**What actually exists:**
```
POST /api/stream/start
Body: {"channel_id": "71386", "source_url": "...", "quality": "medium"}
```

**Fix Required:** Add a new route that Nginx can call:
```python
@app.route('/channel/<channel_id>/start', methods=['POST'])
def channel_start_endpoint(channel_id):
    # Load channel from Redis
    channel_data = _load_json_key(_channel_key(channel_id))
    if not channel_data:
        return jsonify({'error': 'Channel not found'}), 404

    # Start stream
    result = start_stream(
        channel_id,
        channel_data['source_url'],
        channel_data.get('quality', 'medium')
    )
    return jsonify(result)
```

---

### Issue #3: ⚠️ **Upstream Source 403 Forbidden (Without Proxy)**

**Problem:** Direct access to upstream returns 403

**Test Results:**

**Without Proxy:**
```bash
$ curl -I http://s.showplustv.pro:80/live/user11a617ef/pass6278ce42c7e9/71386.ts
HTTP/1.1 403 Forbidden
```

**With SOCKS Proxy (WARP):**
```bash
$ curl --socks5 127.0.0.1:40000 -I http://s.showplustv.pro:80/.../71386.ts
HTTP/1.1 200 OK
Content-Type: video/mp2t
```

**Conclusion:** ✅ Proxy is working and required

**FFmpeg Test:**
```bash
$ ffmpeg -i 'http://s.showplustv.pro:80/.../71386.ts' -t 5 test.ts
[http @ 0x...] HTTP error 403 Forbidden
```

**Reason:** Upstream provider (showplustv.pro) blocks direct access without:
- Proper User-Agent
- Referer header
- IP address through proxy (Cloudflare WARP)

---

## 📊 Current System State

### ✅ Working Components

| Component | Status | Notes |
|-----------|--------|-------|
| Token Validation | ✅ Working | Token found in Redis, valid |
| User Authentication | ✅ Working | User active, not expired |
| M3U Playlist | ✅ Working | Returns 3,931 channels |
| PHP-FPM | ✅ Working | Permissions fixed |
| Redis | ✅ Working | All data accessible |
| Channel Data | ✅ Working | Channel 71386 exists in Redis |
| WARP Proxy | ✅ Working | Port 40000, SOCKS5 active |
| CloudScraper | ✅ Working | Library installed in venv |

### ❌ Not Working Components

| Component | Status | Issue |
|-----------|--------|-------|
| Auto-Stream Start | ❌ Broken | Wrong port + missing endpoint |
| FFmpeg Spawn | ❌ Failing | Can't reach upstream correctly |
| HLS Segments | ❌ Missing | No .ts files generated |

---

## 🔄 Expected vs Actual Flow

### Expected Flow (How it Should Work)

```
1. User opens VLC with stream URL
   └─> GET http://iptvprime.online/live/stream_71386.m3u8?token=XXX

2. Nginx receives request
   └─> Checks /var/www/hls/stream_71386.m3u8
   └─> File doesn't exist or is empty
   └─> try_files triggers @start_stream

3. Nginx @start_stream
   └─> POST http://127.0.0.1:5000/channel/71386/start  # ⬅️ CORRECT PORT

4. Stream API /channel/71386/start
   └─> Load channel from Redis
   └─> channel = {id: 71386, source_url: "http://...", quality: "medium"}
   └─> Call start_stream(71386, source_url, quality)

5. start_stream() function
   └─> Use CloudScraper with WARP proxy
   └─> Fetch upstream with proper headers
   └─> resolved_url = response.url
   └─> Spawn FFmpeg with:
       • Proxy environment variables
       • User-Agent header
       • Referer header
       • Cookies from CloudScraper

6. FFmpeg process
   └─> Reads from upstream (through proxy)
   └─> Transcodes to HLS
   └─> Outputs to /var/www/hls/
       ├─> stream_71386.m3u8
       ├─> stream_71386_001.ts
       ├─> stream_71386_002.ts
       └─> ...

7. Nginx serves HLS
   └─> Returns stream_71386.m3u8 to user
   └─> User's player requests .ts segments
   └─> Nginx serves .ts files
   └─> User watches video! ✅
```

### Actual Flow (What's Happening Now)

```
1. User opens VLC
   └─> GET http://iptvprime.online/live/stream_71386.m3u8?token=XXX

2. Nginx receives request
   └─> Checks /var/www/hls/stream_71386.m3u8
   └─> File exists but is EMPTY (no segments)
   └─> Nginx returns empty M3U8

3. VLC receives empty playlist
   └─> No segments to play
   └─> ❌ No video

Why is the file empty?
└─> @start_stream tries to call port 5001 (wrong!)
└─> OR endpoint /channel/71386/start doesn't exist
└─> FFmpeg never starts
└─> No .ts segments generated
```

---

## 🛠️ Required Fixes

### Fix #1: Update Nginx Configuration

**File:** `/opt/nginx/nginx.conf`

**Change Line ~108:**
```nginx
# FROM:
proxy_pass http://127.0.0.1:5001/channel/$channel_id/start;

# TO:
proxy_pass http://127.0.0.1:5000/channel/$channel_id/start;
```

**Apply:**
```bash
nano /opt/nginx/nginx.conf
# Edit the line
systemctl reload nginx
```

---

### Fix #2: Add Missing Endpoint to Stream API

**File:** `/opt/streamapp/stream_api.py`

**Add after line ~541 (after api_stop_stream):**
```python
@app.route('/channel/<channel_id>/start', methods=['POST', 'GET'])
def channel_start_endpoint(channel_id):
    """
    Endpoint called by Nginx @start_stream fallback
    Automatically starts a stream for a channel
    """
    channel_data = _load_json_key(_channel_key(channel_id))
    if not channel_data:
        return jsonify({'error': 'Channel not found', 'channel_id': channel_id}), 404

    source_url = channel_data.get('source_url')
    if not source_url:
        return jsonify({'error': 'Channel has no source URL'}), 400

    quality = channel_data.get('quality', 'medium')

    # Start the stream
    result = start_stream(channel_id, source_url, quality)

    if result.get('status') in ['started', 'already_running']:
        return jsonify(result), 200
    else:
        return jsonify(result), 500
```

**Apply:**
```bash
nano /opt/streamapp/stream_api.py
# Add the code above
systemctl restart streamapi
```

---

### Fix #3: Verify FFmpeg Environment

**Ensure proxy environment is set when FFmpeg spawns:**

The code already has this at line ~475:
```python
def _spawn(cmd):
    env = os.environ.copy()
    if UPSTREAM_PROXY_URL:
        env.update({
            'http_proxy': UPSTREAM_PROXY_URL,
            'https_proxy': UPSTREAM_PROXY_URL,
            'HTTP_PROXY': UPSTREAM_PROXY_URL,
            'HTTPS_PROXY': UPSTREAM_PROXY_URL,
            'all_proxy': UPSTREAM_PROXY_URL,
            'ALL_PROXY': UPSTREAM_PROXY_URL,
        })
    return subprocess.Popen(cmd, ...)
```

**Verify UPSTREAM_PROXY_URL is set:**
```bash
grep UPSTREAM_PROXY_URL /opt/streamapp/stream_api.py
# Should show: socks5h://127.0.0.1:40000
```

This looks correct ✅

---

## 🧪 Testing After Fixes

### Test 1: Check Nginx Port

```bash
curl -X POST http://localhost:5000/channel/71386/start
# Should return JSON with stream start result
```

### Test 2: Simulate Nginx Request

```bash
# Delete old m3u8 file
rm /var/www/hls/stream_71386.m3u8

# Request from Nginx perspective
curl http://localhost/live/stream_71386.m3u8?token=50e0113420874a1f6decbbf539753cab486f3ee150f177450429218697b040a4

# Wait 5 seconds for FFmpeg to start
sleep 5

# Check if segments exist
ls -lh /var/www/hls/stream_71386*
```

### Test 3: Monitor FFmpeg

```bash
# Watch for FFmpeg process
watch -n 1 'ps aux | grep ffmpeg | grep 71386'

# Check Redis for stream metadata
redis-cli GET stream:71386:pid
redis-cli GET stream:71386:started
```

### Test 4: Full End-to-End Test

```bash
# From VLC or any IPTV player:
# Open URL: http://iptvprime.online/live/stream_71386.m3u8?token=XXX

# Monitor logs:
tail -f /var/log/nginx/access.log
tail -f /var/log/nginx/error.log
journalctl -u streamapi -f
```

---

## 📈 Additional Observations

### Stream Lifecycle

**Current State:**
- Empty M3U8 file exists: `/var/www/hls/stream_71386.m3u8`
- No .ts segments
- No FFmpeg process running
- No Redis PID entry

**After Fixes Should Show:**
1. Nginx receives request
2. Calls stream API on correct port
3. Stream API spawns FFmpeg with proxy
4. FFmpeg generates HLS segments every 4 seconds
5. Redis stores PID and metadata
6. Nginx serves segments to client
7. After 5 minutes idle, FFmpeg auto-stops

---

## 🎯 Summary

### Root Causes

1. **❌ Nginx Port Mismatch** - Calling 5001 instead of 5000
2. **❌ Missing API Endpoint** - /channel/<id>/start doesn't exist
3. **⚠️ Upstream Source Protected** - Requires proxy + headers (already configured)

### Fixes Required

1. ✏️ Edit `/opt/nginx/nginx.conf` - Change port 5001 → 5000
2. ✏️ Edit `/opt/streamapp/stream_api.py` - Add /channel/<id>/start route
3. 🔄 Restart services - nginx and streamapi

### Expected Result

After applying fixes:
- ✅ Auto-stream starting will work
- ✅ FFmpeg will spawn on-demand
- ✅ HLS segments will generate
- ✅ Users can watch streams in VLC/IPTV players
- ✅ Idle streams auto-cleanup after 5 minutes

---

## 📝 Workaround (Until Fixed)

**Manual Stream Start:**
```bash
curl -X POST 'http://localhost:5000/api/stream/start' \
  -H 'Content-Type: application/json' \
  -d '{
    "channel_id": "71386",
    "source_url": "http://s.showplustv.pro:80/live/user11a617ef/pass6278ce42c7e9/71386.ts",
    "quality": "medium"
  }'
```

Then test stream:
```bash
curl http://localhost/live/stream_71386.m3u8?token=XXX
```

---

**Report Generated:** November 7, 2025
**Status:** Diagnosis Complete - Fixes Required
**Priority:** HIGH (Affects all stream playback)

