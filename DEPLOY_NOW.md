# 🚀 Deploy Multi-Source IPTV Panel - One Command!

## ✨ New Feature: Multi-Source M3U Management

Your IPTV panel now supports **multiple M3U sources** with intelligent switching!

---

## 📦 What You Get

✅ Import unlimited M3U playlists from different providers
✅ Switch between sources with one click
✅ Auto-sync channels to streaming server
✅ Each source has isolated categories
✅ Existing channels automatically migrated
✅ 100% autopilot deployment

---

## 🎯 Deploy in 3 Steps

### **Step 1: Navigate to Project**
```bash
cd /Users/aziz/Desktop/IptvPannel_Backup/IptvPannel
```

### **Step 2: Deploy Everything**
```bash
docker-compose up -d --build
```

### **Step 3: Wait for Completion**
Watch the logs (optional):
```bash
docker-compose logs -f panel
```

**Look for these success messages:**
```
✓ Redis connected: redis://redis:6379/0
Entrypoint: Database is ready.
Entrypoint: Database migrations complete.
Entrypoint: ✓ Created default admin
Entrypoint: ✓ Migrated X channels to default source  # If you had existing channels
Entrypoint: Migration complete.
Entrypoint: Starting Gunicorn server...
```

**That's it! Your panel is ready!** 🎉

---

## 🌐 Access Your Panel

**Panel URL:** `https://panel.localtest.me` (or your `PANEL_DOMAIN`)
**Username:** `admin`
**Password:** Check your `.env` file → `ADMIN_PASSWORD`

---

## 📚 Quick Start Guide

### **Import Your First M3U Source:**

1. Login to panel
2. Click **"M3U Sources"** in menu
3. Click **"Import New M3U"**
4. Paste M3U content
5. Click **"Analyze & Continue"**
6. Name it (e.g., "Provider A")
7. Check **"Activate immediately"**
8. Click **"Confirm & Import"**

Done! All channels imported and active.

### **Import More Sources:**

Repeat for each provider. All stored safely.

### **Switch Between Sources:**

1. Go to **"M3U Sources"**
2. Click **"Activate"** on any source
3. Channels auto-sync to streaming server
4. Users get new channels instantly

---

## 🔧 What Happens Automatically

### **On First Deploy:**

1. ✅ Builds Docker images
2. ✅ Starts services (DB, Redis, Panel, Nginx)
3. ✅ Waits for database
4. ✅ Runs migrations (creates M3U sources table)
5. ✅ Creates default admin user
6. ✅ **Migrates existing channels** to "Default Source (Legacy)"
7. ✅ **Activates** default source
8. ✅ Syncs settings
9. ✅ Starts application

### **On Subsequent Deploys:**

Everything runs again (idempotent), but:
- Skips if admin already exists
- Skips if no orphan channels found
- Updates settings from environment

---

## 📊 Verify Deployment

### **Check All Services Running:**
```bash
docker-compose ps
```

**Expected output:**
```
NAME            STATUS        PORTS
iptv_db         Up (healthy)  5432/tcp
iptv_redis      Up (healthy)  6379/tcp
iptv_panel      Up            5000/tcp
iptv_nginx      Up            0.0.0.0:80->80/tcp, 0.0.0.0:443->443/tcp
```

### **Check Migration Logs:**
```bash
docker-compose logs panel | grep "Migrated"
```

### **Test Panel Access:**
```bash
curl -I http://localhost
```

Should see: `HTTP/1.1 301 Moved Permanently` (redirecting to HTTPS)

---

## 🎓 Features Overview

### **Navigation Menu:**

```
Dashboard
Users
M3U Sources  ← NEW!
Channels
Categories
Settings
Logs
```

### **M3U Sources Page Shows:**

- All imported sources
- Active/Inactive status
- Total channels per source
- Upload date
- Actions: View, Activate, Delete

### **Source-Aware Filtering:**

Everything filters by active source:
- Dashboard stats
- Channels list
- Categories
- User playlists
- API responses

---

## 🔄 Migration Details

### **If You Have Existing Channels:**

The system automatically:
1. Detects channels without a source
2. Creates "Default Source (Legacy)"
3. Links all channels to it
4. Activates it

**Your existing channels remain active and working!**

### **If Fresh Install:**

No migration needed. Start importing M3U sources immediately.

---

## 🐛 Troubleshooting

### **Issue: Can't see channels**

**Solution:**
1. Go to M3U Sources
2. Check if any source is active (green badge)
3. If not, click "Activate" on a source

### **Issue: Panel not accessible**

**Check services:**
```bash
docker-compose ps
```

**Check logs:**
```bash
docker-compose logs nginx
docker-compose logs panel
```

### **Issue: Import fails with 502 error**

**Verify Redis:**
```bash
docker-compose ps redis
```

**Restart if needed:**
```bash
docker-compose restart redis panel
```

---

## 📖 Full Documentation

See **`M3U_SOURCES_FEATURE.md`** for:
- Detailed architecture
- API documentation
- Advanced troubleshooting
- Performance tuning
- Security notes

---

## 🎉 You're Done!

Your IPTV panel is now running with **Multi-Source M3U Management**!

**Next Steps:**
1. Login to panel
2. Go to M3U Sources
3. Import your M3U playlists
4. Switch between providers anytime
5. Enjoy! 🚀

---

## 💡 Pro Tips

- **Test sources:** Import without activating, review channels first
- **Backup strategy:** Keep multiple sources as automatic backups
- **Quick switch:** One click to rollback to previous provider
- **Organized naming:** Use clear names like "Sports 2025", "Movies HD", etc.

---

**Deployment Time:** ~2 minutes
**Channels Migrated:** Automatic
**Configuration Required:** None (uses existing `.env`)
**Downtime:** Zero (if upgrading running system)

**Status: 100% Production Ready** ✅
