# Grafana Auto-Dashboard Deployment System

Automatically discovers z/OS subsystems from Prometheus and creates organized Grafana dashboards in real-time.

## Table of Contents
- [Overview](#overview)
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Configuration](#configuration)
- [Usage](#usage)
- [Folder Structure](#folder-structure)
- [Troubleshooting](#troubleshooting)
- [Support](#support)

---

## Overview

This system automates the creation and management of Grafana dashboards for z/OS monitoring. It:
- Queries Prometheus for z/OS subsystem metrics
- Automatically detects subsystem types (CICS, DB2, MQ, IMS)
- Creates hierarchical folder structures in Grafana
- Deploys type-specific dashboards
- Tracks state to avoid redundant deployments

### Architecture

```
z/OS Systems → OpenTelemetry → Kafka → OTel Collector → Prometheus
                                                            ↓
                                                    Auto-Dashboard Script
                                                            ↓
                                                         Grafana
```

---

## Features

- **Auto-Discovery**: Detects new subsystems at configured intervals
- **Hierarchical Organization**: `zos-metrics → SYSPLEX → SYSTEM → SUBSYSTEM → Dashboard`
- **Type-Aware**: Different dashboards for CICS, DB2, MQ, IMS
- **High Performance**: Deploys 50+ dashboards in 3-5 seconds
- **State Management**: Remembers deployed dashboards across restarts
- **Parallel Processing**: 50 concurrent operations
- **Zero Downtime**: Runs continuously in background

---

## Prerequisites

### Required Software
- **Bash**: Version 4.0 or higher (with `jobs` command for parallel processing)
- **curl**: Version 7.0 or higher (for API calls with `-G`, `-s`, `-w` flags)
- **jq**: Version 1.5 or higher (for JSON processing)
- **md5sum**: GNU coreutils 8.0+ (or `md5` on macOS) for generating unique IDs
- **date**: GNU coreutils 8.0+ (for `-d` flag support, or use `gdate` on macOS)


### Required Services
- **Grafana**: Version 11.0 or higher
- **Prometheus**: Version 2.0 or higher with z/OS metrics

### Grafana API Key
You need a Grafana API key with **Admin** role:
1. Login to Grafana
2. Go to **Administration** → **Service Accounts**
3. Click **Add service account**
4. Name: `auto-dashboard-script`
5. Role: **Admin** (Note: Editor role does NOT have sufficient permissions for folder/dashboard creation)
6. Click **Add service account token**
7. Copy the generated token

**Important:** The Editor role lacks permissions for creating folders and managing dashboards. You must use Admin role.
---

## Installation

### Step 1: Extract Package
```bash
# Extract the package
tar -xzf grafana-auto-dashboard.tar.gz
cd grafana-auto-dashboard

# Verify contents
ls -la
# Should see:
# - auto-sync.sh
# - config.env
# - README.md
# - dashboards/
```

### Step 2: Install Dependencies
```bash
# On RHEL/CentOS
sudo yum install -y jq curl

# On Ubuntu/Debian
sudo apt-get install -y jq curl

# Verify installation
jq --version
curl --version
```

### Step 3: Make Script Executable
```bash
chmod +x auto-sync.sh
```

---

## Configuration

### Edit Configuration File
```bash
vi config.env
```

### Required Settings

#### 1. Grafana Configuration
```bash
# Your Grafana server URL
GRAFANA_URL=http://your-grafana-server:3000

# Your Grafana API key (from Prerequisites step)
GRAFANA_API_KEY=<grafana-api-key>
```

#### 2. Prometheus Configuration
```bash
# Your Prometheus server URL
PROM_URL=http://your-prometheus-server:9090
```

### Optional Settings

#### 3. Script Behavior
```bash
# Check interval (seconds) - how often to scan for new subsystems in prometheus
# Check intervals (seconds) - how often sync the cache with grafana
CHECK_INTERVAL=10  # Default: 10 seconds
                    # Adjust based on your needs:
                    # - 60 = 1 minute (frequent checks)
                    # - 300 = 5 minutes (balanced)
                    # - 600 = 10 minutes (less frequent)

# Parallel operations - higher = faster but more API load
MAX_PARALLEL=50     # Default: 50

# Root folder name in Grafana
ROOT_FOLDER_NAME=zos-metrics  # Default: zos-metrics
```

#### 4. Advanced Settings
```bash
# Dashboard templates directory
DASHBOARD_DIR=dashboards

# State file location
STATE_FILE=.grafana_deployed_state
```

### Configuration Validation
```bash
# Test Grafana connectivity
curl -H "Authorization: Bearer $GRAFANA_API_KEY" \
  http://your-grafana-server:3000/api/health

# Test Prometheus connectivity
curl http://your-prometheus-server:9090/api/v1/label/__name__/values
```

---

## Usage

### Running the Script

#### Option 1: Foreground (for testing)
```bash
./auto-sync.sh
```

**Expected Output:**
```
[2026-02-11 21:18:35] Loading configuration from /root/lbDir/dynamic-dashboard/zapm-perf-suite/zTC/combined-mock-source-code/metric-log-source-code/dynamic-script/config.env
[2026-02-11 21:18:35] Starting Grafana hierarchy sync (OPTIMIZED MODE)
[2026-02-11 21:18:35] Checking Grafana datasource setup...
[2026-02-11 21:18:35] ✓ Datasource 'prometheusDatasource' already exists in Grafana
[2026-02-11 21:18:35] No previous state file found, starting fresh
[2026-02-11 21:18:35] Fetching all existing folders from Grafana...
[2026-02-11 21:18:35] Cached 0 existing folders
[2026-02-11 21:18:35] Fetching metrics from Prometheus...
[2026-02-11 21:18:35] Processing metrics and building hierarchy...
[2026-02-11 21:18:35] Found 13 new dashboards to deploy (0 already deployed, 13 total)
[2026-02-11 21:18:35] Creating root folder (zos-metrics)...
[2026-02-11 21:18:35] Creating SYSPLEX folders...
[2026-02-11 21:18:36] Creating SYSTEM/LPAR folders...
[2026-02-11 21:18:36] Creating SUBSYSTEM folders...
[2026-02-11 21:18:36] Deploying 13 dashboards in parallel...
[2026-02-11 21:18:37] Waiting for dashboard deployment to complete...
[2026-02-11 21:18:37] Saved 13 deployed dashboards to state file
[2026-02-11 21:18:37] ✓ Sync complete in 2s. Deployed 13 new dashboards (13 total tracked).
[2026-02-11 21:18:37] Sleeping 10s...
```

**In case where user has deleted any active folder for which traffic is still coming, this is how the script will respond and create those folders again**

```
2026-02-13 08:56:09] Loaded 13 previously deployed dashboards from state file
[2026-02-13 08:56:09] Validating 13 cached dashboards against Grafana...
[2026-02-13 08:56:09]   ⚠ Dashboard deleted from Grafana: LPAR400J|SYSG|DB2|DC1V
[2026-02-13 08:56:09]   ⚠ Dashboard deleted from Grafana: LPAR400J|SYSG|CICS|CICSCB06
[2026-02-13 08:56:09]   ⚠ Dashboard deleted from Grafana: LPAR400J|SYSG|CICS|CICSCB12
[2026-02-13 08:56:09]   ⚠ Dashboard deleted from Grafana: LPAR400J|SYSG|CICS|CICSCB08
[2026-02-13 08:56:09]   ⚠ Dashboard deleted from Grafana: LPAR400J|SYSG|DB2|DD1B
[2026-02-13 08:56:09]   ⚠ Dashboard deleted from Grafana: LPAR400J|SYSG|CICS|CICSCB07
[2026-02-13 08:56:09]   ⚠ Dashboard deleted from Grafana: LPAR400J|SYSG|DB2|DC1W
[2026-02-13 08:56:09]   ⚠ Dashboard deleted from Grafana: LPAR400J|SYSG|DB2|DC1K
[2026-02-13 08:56:09]   ⚠ Dashboard deleted from Grafana: LPAR400J|SYSG|DB2|DC1X
[2026-02-13 08:56:09]   ⚠ Dashboard deleted from Grafana: LPAR400J|SYSG|DB2|DC1E
[2026-02-13 08:56:09]   ⚠ Dashboard deleted from Grafana: LPAR400J|SYSG|DB2|DC1Y
[2026-02-13 08:56:09]   ⚠ Dashboard deleted from Grafana: LPAR400J|SYSG|CICS|CICSCB05
[2026-02-13 08:56:09]   ⚠ Dashboard deleted from Grafana: LPAR400J|SYSG|CICS|CICSCB11
[2026-02-13 08:56:09] Removed 13 deleted dashboard(s) from cache
[2026-02-13 08:56:09] These dashboards will be recreated in the next sync cycle
[2026-02-13 08:56:09] Saved 0 deployed dashboards to state file
[2026-02-13 08:56:09] Fetching all existing folders from Grafana...
[2026-02-13 08:56:09] Cached 0 existing folders
[2026-02-13 08:56:10] Fetching metrics from Prometheus...
[2026-02-13 08:56:10] Processing metrics and building hierarchy...
[2026-02-13 08:56:10] Found 13 new dashboards to deploy (0 already deployed, 13 total)
[2026-02-13 08:56:10] Creating root folder (zos-metrics)...
[2026-02-13 08:56:10] Creating SYSPLEX folders...
[2026-02-13 08:56:10] Creating SYSTEM/LPAR folders...
[2026-02-13 08:56:10] Creating SUBSYSTEM folders...
[2026-02-13 08:56:11] Deploying 13 dashboards in parallel...
[2026-02-13 08:56:11] Waiting for dashboard deployment to complete...
[2026-02-13 08:56:11] Saved 13 deployed dashboards to state file
[2026-02-13 08:56:11] ✓ Sync complete in 2s. Deployed 13 new dashboards (13 total tracked).
[2026-02-13 08:56:11] Sleeping 10s...
```


#### Option 2: Background (for production)
```bash
# Start in background
nohup ./auto-sync.sh > grafana-sync.log 2>&1 &

# Save process ID
echo $! > grafana-sync.pid

# Check status
tail -f grafana-sync.log
```

#### Option 3: Systemd Service (recommended for production)
```bash
# Create service file
sudo vi /etc/systemd/system/grafana-auto-dashboard.service
```

**Service file content:**
```ini
[Unit]
Description=Grafana Auto-Dashboard Deployment
After=network.target

[Service]
Type=simple
User=your-user
WorkingDirectory=/path/to/grafana-auto-dashboard
ExecStart=/path/to/grafana-auto-dashboard/auto-sync.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

**Enable and start:**
```bash
sudo systemctl daemon-reload
sudo systemctl enable grafana-auto-dashboard
sudo systemctl start grafana-auto-dashboard

# Check status
sudo systemctl status grafana-auto-dashboard

# View logs
sudo journalctl -u grafana-auto-dashboard -f
```

### Stopping the Script

#### If running in foreground:
```bash
# Press Ctrl+C
```

#### If running in background:
```bash
# Find process ID
cat grafana-sync.pid

# Stop process
kill $(cat grafana-sync.pid)
```

#### If running as systemd service:
```bash
sudo systemctl stop grafana-auto-dashboard
```

---

## Folder Structure

### Package Contents
```
grafana-auto-dashboard/
├── auto-sync.sh               # Main script
├── config.env                 # Configuration file
├── README.md                  # This file
└── dashboards/                # Dashboard templates
    ├── cics-metrics.json      # CICS dashboard template
    ├── db2-metrics.json       # DB2 dashboard template
    ├── mq-metrics.json        # MQ dashboard template
    ├── ims-metrics.json       # IMS dashboard template
```

### Grafana Folder Hierarchy
```
zos-metrics/                   # Root folder
└── LPAR400J/                  # SYSPLEX
    └── SYSG/                  # SYSTEM
        ├── CICS/              # Subsystem type
        │   ├── CICSR01E       # Dashboard
        │   ├── CICSR02E       # Dashboard
        │   └── ...
        ├── DB2/
        │   ├── DC1E           # Dashboard
        │   ├── DC1K           # Dashboard
        │   └── ...
        ├── MQ/
        │   └── M31A           # Dashboard
        └── IMS/
            └── IMS1           # Dashboard
```

### Generated Files
```
.grafana_deployed_state        # Tracks deployed dashboards
grafana-sync.log              # Log file (if using nohup)
grafana-sync.pid              # Process ID (if using nohup)
```

---

## Troubleshooting

### Issue: Script fails to start

**Error:** `Configuration file not found`
```bash
# Solution: Ensure config.env exists in same directory as script
ls -la config.env
```

**Error:** `GRAFANA_URL not set`
```bash
# Solution: Edit config.env and set required variables
vi config.env
```

### Issue: Cannot connect to Grafana

**Error:** `curl: (7) Failed to connect`
```bash
# Check Grafana is running
curl http://your-grafana-server:3000/api/health

# Check firewall
telnet your-grafana-server 3000

# Verify URL in config.env (no trailing slash)
GRAFANA_URL=http://your-grafana-server:3000  # Correct
GRAFANA_URL=http://your-grafana-server:3000/ # Wrong
```

**Error:** `401 Unauthorized`
```bash
# Solution: Check API key is valid
curl -H "Authorization: Bearer $GRAFANA_API_KEY" \
  http://your-grafana-server:3000/api/user

# If invalid, generate new API key in Grafana UI
```

### Issue: Cannot connect to Prometheus

**Error:** `curl: (7) Failed to connect`
```bash
# Check Prometheus is running
curl http://your-prometheus-server:9090/api/v1/status/config

# Verify URL in config.env
PROM_URL=http://your-prometheus-server:9090
```

### Issue: No dashboards created

**Check 1: Verify metrics exist**
```bash
# Check if Prometheus has z/OS metrics
curl "$PROM_URL/api/v1/label/subsystem/values" | jq '.data'

# Should return subsystem names like: CICS01, DC1E, M31A, etc.
```

**Check 2: Check script logs**
```bash
# Look for errors in output
tail -100 grafana-sync.log

# Common issues:
# - "Found 0 new dashboards" → No metrics in Prometheus
# - "403 Forbidden" → API key lacks permissions
# - "Template not found" → Dashboard templates missing
```

**Check 3: Verify dashboard templates**
```bash
# Ensure templates exist
ls -la dashboards/*.json

# Should see:
# - cics-metrics.json
# - db2-metrics.json
# - mq-metrics.json
# - ims-metrics.json
# - unknown-metrics.json
```

### Issue: Dashboards not updating

**Solution: Clear state file**
```bash
# Remove state file to force redeployment
rm .grafana_deployed_state

# Restart script
./auto-sync.sh
```

### Issue: Script is slow

**Check 1: Reduce parallel operations**
```bash
# Edit config.env
MAX_PARALLEL=20  # Reduce from 50 to 20
```

**Check 2: Increase check interval**
```bash
# Edit config.env
CHECK_INTERVAL=600  # Check every 10 minutes instead of default
```

**Check 3: Check Prometheus response time**
```bash
# Time the query
time curl -s "$PROM_URL/api/v1/series?match[]={zos_smf_id!=\"\"}" > /dev/null

# Should be < 5 seconds
# If slow, Prometheus may need optimization
```

### Issue: Permission denied

**Error:** `Permission denied: ./auto-sync.sh`
```bash
# Solution: Make script executable
chmod +x auto-sync.sh
```

**Error:** `Permission denied: config.env`
```bash
# Solution: Fix file permissions
chmod 644 config.env
```

---

## Monitoring

### Check Script Status
```bash
# If running as systemd service
sudo systemctl status grafana-auto-dashboard

# If running in background
ps aux | grep auto-sync.sh

# Check process ID file
cat grafana-sync.pid
```

### View Logs
```bash
# If using systemd
sudo journalctl -u grafana-auto-dashboard -f

# If using nohup
tail -f grafana-sync.log

# Last 100 lines
tail -100 grafana-sync.log
```

### Check Deployed Dashboards
```bash
# View state file
cat .grafana_deployed_state | wc -l  # Count deployed dashboards

# View in Grafana
# Navigate to: Dashboards → Browse → zos-metrics
```

---

## Updating

### Update Dashboard Templates
```bash
# 1. Backup existing templates
cp -r dashboards dashboards.backup

# 2. Replace templates
cp new-templates/*.json dashboards/

# 3. Clear state to redeploy with new templates
rm .grafana_deployed_state

# 4. Restart script
sudo systemctl restart grafana-auto-dashboard
```

### Update Script
```bash
# 1. Stop script
sudo systemctl stop grafana-auto-dashboard

# 2. Backup current version
cp auto-sync.sh auto-sync.sh.backup

# 3. Replace script
cp new-auto-sync.sh auto-sync.sh
chmod +x auto-sync.sh

# 4. Start script
sudo systemctl start grafana-auto-dashboard
```

---

## Support

### Getting Help

**Check logs first:**
```bash
tail -100 grafana-sync.log
```

**Collect diagnostic information:**
```bash
# System info
uname -a
bash --version
jq --version

# Configuration
cat config.env | grep -v API_KEY  # Hide sensitive data

# Recent logs
tail -50 grafana-sync.log

# State
wc -l .grafana_deployed_state
```

### Common Questions

**Q: How often does the script check for new subsystems?**  
A: Based on your `CHECK_INTERVAL` setting in config.env (default: 10 seconds). You can adjust this to any value.

**Q: Can I run multiple instances?**  
A: No, only one instance should run per Grafana instance to avoid conflicts.

**Q: How do I add a new subsystem type?**  
A: Create a new dashboard template in `dashboards/` and update the `detect_subsystem()` function in the script.

**Q: Can I customize dashboard templates?**  
A: Yes, edit the JSON files in `dashboards/` directory. Clear state file to redeploy.

**Q: How do I delete old dashboards?**  
A: Manually delete in Grafana UI or use Grafana API. The script only creates/updates, never deletes.

---

## License

Copyright © 2026. All rights reserved.

---

## Quick Start Summary

```bash
# 1. Extract package
tar -xzf grafana-auto-dashboard.tar.gz
cd grafana-auto-dashboard

# 2. Install dependencies
sudo yum install -y jq curl

# 3. Configure
vi config.env
# Set: GRAFANA_URL, GRAFANA_API_KEY, PROM_URL
# Optional: Adjust CHECK_INTERVAL (default: 10 seconds)

# 4. Make executable
chmod +x auto-sync.sh

# 5. Test run
./auto-sync.sh

# 6. Run in background (production)
nohup ./auto-sync.sh > grafana-sync.log 2>&1 &
echo $! > grafana-sync.pid

# 7. Check Grafana
# Navigate to: Dashboards → Browse → zos-metrics
```

**That's it! Your dashboards will auto-deploy at your configured interval.**