# PoolForge

<p align="center">
  <img src="https://raw.githubusercontent.com/Paul-Cradduck/PoolForge-Releases/main/logo/poolforge_banner1.png" alt="PoolForge" width="400">
</p>


Open-source hybrid RAID storage manager for Ubuntu LTS that solves the biggest problem with traditional RAID: wasted capacity on mixed-size disks. Instead of limiting every drive to the smallest disk's size, PoolForge uses a tiered slicing algorithm to extract maximum usable space from every disk in the pool — typically 75-85% efficiency versus 30-40% with conventional RAID. Disks can be added or removed online, and the entire pool can be migrated to new hardware by serial number matching.

PoolForge runs as a single binary with a built-in web dashboard, safety daemon with SMART monitoring and scrub scheduling, rsync backup jobs with retention policies, SMB/NFS sharing, webhook and SMTP alerting, and full system backup/restore. All state is stored as atomic JSON with redundant copies on the pool itself, so your configuration survives even if the boot drive fails. No proprietary hardware, no vendor lock-in — just standard Linux tools (mdadm, LVM, ext4) on any x86_64 machine with two or more disks.

```
┌─────────────────────────────────────────────────────────────┐
│                     /mnt/poolforge/mypool                    │
│                      Single ext4 Volume                      │
├─────────────────────────────────────────────────────────────┤
│                        LVM (lv_pool)                         │
├───────────────────┬──────────────────┬──────────────────────┤
│    md0 (RAID5)    │   md1 (RAID5)    │    md2 (standalone)  │
│     Tier 0        │    Tier 1        │      Tier 2          │
│    9 GB usable    │   4 GB usable    │    5 GB usable       │
├────┬────┬────┬────┼────┬────┬────┬───┼────┬───────┬────┬───┤
│ 3G │ 3G │ 3G │ 3G │    │ 2G │ 2G │2G│    │       │    │5G │
├────┴────┴────┴────┼────┴────┴────┴───┼────┴───────┴────┴───┤
│   3 GB disk       │   5 GB disk      │   5 GB disk         │
│                   │                  │                      │
│                   │                  │   10 GB disk ────────┤
└───────────────────┴──────────────────┴──────────────────────┘
```

## How It Works

PoolForge implements a tiered slicing algorithm:

1. **Sorts disks by capacity** and computes capacity tiers — each tier represents a slice size where a group of disks can contribute equally
2. **Creates RAID arrays** for each tier (RAID1 for 2 disks, RAID5 for 3+, RAID6 for dual parity)
3. **Combines arrays into a single LVM volume** with an ext4 filesystem
4. **Maximizes usable space** — larger disks contribute their extra capacity to higher tiers that smaller disks can't reach

### Tiered Slicing Algorithm

```
Input: 3GB + 5GB + 5GB + 10GB disks (sorted)

Step 1: Compute tiers from capacity differences

     3GB    5GB    5GB    10GB
      │      │      │      │
      ├──────┼──────┼──────┤  Tier 0: all 4 disks × 3GB slice
      │      ├──────┼──────┤  Tier 1: 3 disks × 2GB slice (5-3=2)
      │      │      │      │  Tier 2: 1 disk × 5GB slice (10-5=5)
      ▼      ▼      ▼      ▼

Step 2: Build RAID arrays per tier

  Tier 0:  [3G] [3G] [3G] [3G]  →  RAID5 (4 disks)  =  9 GB usable
  Tier 1:       [2G] [2G] [2G]  →  RAID5 (3 disks)  =  4 GB usable
  Tier 2:                  [5G]  →  standalone        =  5 GB usable
                                                       ──────────────
                                                        18 GB usable
Step 3: LVM combines all arrays
                                    18 GB from 23 GB raw = 78% efficiency
  vs traditional RAID5 (3GB uniform): 9 GB = 39% efficiency
```

### Per-Disk Slice Map

```
  ┌──────────────────────────────────────────────────────┐
  │ Disk 1 (3GB)   [████ Tier 0 ████]                    │
  │ Disk 2 (5GB)   [████ Tier 0 ████][██ Tier 1 ██]      │
  │ Disk 3 (5GB)   [████ Tier 0 ████][██ Tier 1 ██]      │
  │ Disk 4 (10GB)  [████ Tier 0 ████][██ Tier 1 ██][████ Tier 2 ████] │
  └──────────────────────────────────────────────────────┘
         ▼                  ▼                  ▼
     md0 (RAID5)       md1 (RAID5)       md2 (standalone)
         └──────────────────┼──────────────────┘
                            ▼
                    LVM Volume Group
                            ▼
                   Single ext4 Mount
```

### Storage Stack

PoolForge builds on standard Linux storage primitives:

```
  ┌────────────────────────────────┐
  │     /mnt/poolforge/mypool      │  ext4 filesystem
  ├────────────────────────────────┤
  │     LVM Logical Volume         │  lv_pool
  ├────────────────────────────────┤
  │     LVM Volume Group           │  vg_poolforge_mypool
  ├──────────┬──────────┬──────────┤
  │   md0    │   md1    │   md2    │  mdadm arrays (one per tier)
  ├──────────┴──────────┴──────────┤
  │     GPT partitions (slices)    │  one partition per tier per disk
  ├────────────────────────────────┤
  │     Physical disks             │  /dev/sd*, /dev/nvme*
  └────────────────────────────────┘
```

| Layer | Tool | Purpose |
|-------|------|---------|
| Partitioning | `gdisk` | GPT partition tables, one partition per tier slice |
| RAID | `mdadm` | Software RAID arrays per tier |
| Volume Management | `lvm2` | Combines all arrays into one volume group |
| Filesystem | `mkfs.ext4` / `resize2fs` | Single ext4 mount point |

## Install

```bash
curl -sSL https://raw.githubusercontent.com/Paul-Cradduck/PoolForge-Releases/main/install.sh | sudo bash
```

Installs the binary, dependencies (mdadm, lvm2, smartmontools, samba, nfs-kernel-server), and a systemd service.

### Configure

```bash
sudo nano /etc/poolforge.conf
```

```ini
POOLFORGE_USER=admin
POOLFORGE_PASS=yourpassword
POOLFORGE_ADDR=0.0.0.0:8080
```

```bash
sudo systemctl start poolforge
```

### Update

To update PoolForge to the latest version, simply re-run the installer:

```bash
curl -sSL https://raw.githubusercontent.com/Paul-Cradduck/PoolForge-Releases/main/install.sh | sudo bash
sudo systemctl restart poolforge
```

The installer will download the latest binary and preserve your existing configuration and pool metadata.

## Uninstall

```bash
curl -sSL https://raw.githubusercontent.com/Paul-Cradduck/PoolForge-Releases/main/uninstall.sh | sudo bash
```

Removes the binary, service, and optionally config/metadata. Never touches your arrays, LVM volumes, or data.

## Web Portal

Dark-themed single-page dashboard at `http://your-server:8080`.

```
┌─────────────────────────────────────────────────────────────────┐
│  PoolForge Dashboard                              [Create Pool] │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Pool: mypool (healthy)                    4 disks │ parity1    │
│                                                                 │
│  Capacity  [██████████████████░░░░░░░░▓▓▓▓▓▓░░]                │
│             Used: 12GB   Free: 6GB   Parity: 5GB   OH: 1GB     │
│                                                                 │
│  ┌─────────┬──────────────────────────────────────────────┐     │
│  │ sda 3GB │ [████ T0 ████]                               │     │
│  │ sdb 5GB │ [████ T0 ████][██ T1 ██]                     │     │
│  │ sdc 5GB │ [████ T0 ████][██ T1 ██]                     │     │
│  │ sdd 10G │ [████ T0 ████][██ T1 ██][████ T2 ████]       │     │
│  └─────────┴──────────────────────────────────────────────┘     │
│                                                                 │
│  Arrays:  md0 RAID5 [healthy]  md1 RAID5 [healthy]              │
│                                                                 │
│  [Add Disk]  [Remove Disk]  [Fail Disk]  [Replace Disk]        │
│                                                                 │
│  Safety: SMART ✓  Scrub ✓  Backup ✓  Boot ✓                    │
│                                                                 │
│  Logs ──────────────────────────────────────────────────        │
│  08:31 SMART check passed for all disks                         │
│  08:30 Metadata backed up to /mnt/poolforge/mypool/.poolforge   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**Pool Management:**
- Create pools with disk selectors and auto-select
- Live capacity preview during creation with tier breakdown
- Warnings for excluded smaller disks that can never be added later

**Capacity Breakdown:**
- Stacked bar: used, free, parity/redundancy, overhead, expansion potential
- Per-disk slice map showing tier colors and free space

**Disk Operations:**
- Add disk — preview shows projected capacity gain and new tiers
- Remove disk — safety check prevents removal if it would destroy data
- Fail disk — simulate failure for testing
- Replace disk — swap a failed disk with a new one

**Monitoring:**
- Live RAID rebuild progress via SSE (auto-detected, no button click)
- Safety daemon status panel (SMART, scrub, backup, boot config)
- Alerts panel with history
- Scrollable logs with clear button

**Disk Health:**
- Dedicated SMART health page with per-disk attribute tables
- Problem drives highlighted with red borders (reallocated sectors, pending sectors, high temp, high hours)
- Expandable full SMART attribute view per disk
- Disks show as offline when enclosure is powered off or device is missing

**Rsync Backup Jobs:**
- Create/edit backup jobs with source/target path browser
- Schedule by day/time or run manually
- Delete confirmation dialog with option to include `--delete` for both runs and dry runs
- Retention policy per job (keep last N runs, keep for N days)
- Full rsync log capture — click 📋 on any history entry to see the complete output
- `--ignore-errors` ensures deletions proceed even when source has I/O errors

**Shares:**
- Custom mount paths per share — point each share at any directory on the pool
- SMB and NFS protocol selection per share
- Guest access, read-only, browsable options

**Alerts:**
- Webhook notifications (Slack, Discord, custom endpoints)
- SMTP email alerts with full configuration in Settings UI
- Test alert button to verify configuration
- Runtime config updates — no restart required

**System Backup:**
- Download full system backup as ZIP from Settings tab
- Includes pool metadata, disk serials/positions, all job configs, SSH keys, server config
- CLI: `poolforge system export` / `poolforge system restore`

## CLI

```bash
# Pool operations
poolforge pool create --name mypool --disks /dev/sda,/dev/sdb,/dev/sdc --parity parity1
poolforge pool list
poolforge pool status mypool
poolforge pool delete mypool

# Disk lifecycle
poolforge pool add-disk mypool --disk /dev/sdd
poolforge pool remove-disk mypool --disk /dev/sda
poolforge pool fail-disk mypool --disk /dev/sda
poolforge pool replace-disk mypool --old /dev/sda --new /dev/sdd

# Import pool from disks moved from another system
poolforge pool import

# Start/stop pools (external enclosures)
poolforge pool start mypool
poolforge pool stop mypool

# Web portal with safety daemon
poolforge serve --addr 0.0.0.0:8080 --user admin --pass secret

# System backup and restore
poolforge system export -o poolforge-backup.zip
poolforge system restore poolforge-backup.zip
```

## Disk Lifecycle

### Add Disk — Online Expansion

```
Before: 3 disks (3GB + 5GB + 5GB)          After: + 10GB disk added
                                            
  Tier 0: [3G][3G][3G] → RAID5 = 6GB       Tier 0: [3G][3G][3G][3G] → RAID5 = 9GB
  Tier 1:     [2G][2G] → RAID1 = 2GB       Tier 1:     [2G][2G][2G] → RAID5 = 4GB
                                            Tier 2:              [5G] → standalone
                         ─────────                                      ──────────
                          8GB usable                                     18GB usable

  ┌──────────────────────────────────────────────────────────────┐
  │  1. New disk partitioned into slices matching existing tiers │
  │  2. Slices added to existing md arrays                       │
  │  3. Arrays reshape online (RAID1→RAID5, grow capacity)       │
  │  4. New tiers created for remaining space                    │
  │  5. LVM auto-expands when reshape completes                  │
  │  6. Filesystem grows online — zero downtime                  │
  └──────────────────────────────────────────────────────────────┘
```

### Remove Disk

```
  ┌─────────────────────────────────────────────────────────┐
  │  Safety check: can the pool survive without this disk?  │
  │                                                         │
  │  ✓ Enough members remain in each array for redundancy   │
  │  ✓ No data loss — RAID can tolerate the removal         │
  │  → mdadm --fail + --remove from each array              │
  │  → Pool continues operating in degraded mode            │
  └─────────────────────────────────────────────────────────┘
```

### Replace Failed Disk

```
  Failed disk              New disk (same or larger)
  ┌──────────┐             ┌──────────┐
  │ /dev/sda │──── swap ──▶│ /dev/sde │
  │  FAILED  │             │  HEALTHY │
  └──────────┘             └──────────┘
        │                        │
        ▼                        ▼
  Removed from arrays      Added to arrays
                           Rebuild starts
                           ████████░░░░ 67%
                           Rebuild complete ✓
```

## Pool Import / Disk Migration

Move disks to a new machine and recover your pool:

```bash
# On new machine with disks attached:
sudo apt install mdadm lvm2
sudo poolforge pool import
```

```
  Source Machine                          Destination Machine
  ┌──────────────────┐                   ┌──────────────────┐
  │ /dev/sda (3GB)   │                   │ /dev/nvme1n1 (5GB)│  ← different
  │ /dev/sdb (5GB)   │  move disks       │ /dev/nvme2n1 (3GB)│    device names,
  │ /dev/sdc (5GB)   │ ──────────────▶   │ /dev/nvme3n1 (10G)│    different order
  │ /dev/sdd (10GB)  │                   │ /dev/nvme4n1 (5GB)│
  └──────────────────┘                   └──────────────────┘
                                                  │
                                                  ▼
                                         poolforge pool import
                                                  │
                                    ┌─────────────┼─────────────┐
                                    ▼             ▼             ▼
                              Assemble md    Match disks    Remap device
                              from super-    by capacity    names in
                              blocks         (50MB tol.)    metadata
                                    │             │             │
                                    └─────────────┼─────────────┘
                                                  ▼
                                         Pool recovered ✓
```

Import automatically:
- Assembles md arrays from superblocks (works regardless of device name changes)
- Finds the PoolForge LVM volume group
- Reads backup metadata from the pool mount point
- Remaps device names by matching disk capacities
- Remaps md device names by matching array members
- Fixes stale superblocks if arrays were modified before migration

Same-size disks are handled correctly — PoolForge gives identical disks identical slice layouts, making them interchangeable.

## Safety Features

All run automatically via the background safety daemon:

```
  ┌─────────────────────────────────────────────────────────┐
  │                    Safety Daemon                         │
  │                                                         │
  │   ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌───────┐ │
  │   │  SMART   │  │  Scrub   │  │ Metadata │  │ Boot  │ │
  │   │ Monitor  │  │Scheduler │  │  Backup  │  │Config │ │
  │   │  5 min   │  │ Weekly   │  │  Hourly  │  │On save│ │
  │   └────┬─────┘  └────┬─────┘  └────┬─────┘  └───┬───┘ │
  │        │             │             │             │      │
  │        ▼             ▼             ▼             ▼      │
  │   ┌──────────────────────────────────────────────────┐  │
  │   │              Alert Engine                        │  │
  │   │         Webhook  │  SMTP Email                   │  │
  │   └──────────────────────────────────────────────────┘  │
  │                                                         │
  │   SIGINT/SIGTERM → backup metadata → stop scrubs → exit │
  └─────────────────────────────────────────────────────────┘
```

| Feature | Interval | Description |
|---------|----------|-------------|
| SMART Monitoring | 5 min | Checks disk health via smartctl, alerts on failures |
| Scrub Scheduling | Weekly | Triggers mdadm array checks to detect silent corruption |
| Metadata Backup | Hourly | Copies metadata to pool mount point for disaster recovery |
| Boot Config | On backup | Generates mdadm.conf + update-initramfs for auto-assembly |
| Graceful Shutdown | SIGINT/SIGTERM | Backs up metadata and stops scrubs before exit |

## Parity Modes

```
  parity1 (1-disk fault tolerance)        parity2 (2-disk fault tolerance)
  ┌──────────────────────────┐           ┌──────────────────────────┐
  │  2 disks → RAID1 (mirror)│           │  3 disks → RAID6         │
  │  3+ disks → RAID5        │           │  4+ disks → RAID6        │
  │                          │           │                          │
  │  [D1] [D2] [P ]          │           │  [D1] [D2] [P ] [Q ]     │
  │  [D3] [P ] [D4]          │           │  [D3] [P ] [Q ] [D4]     │
  │  [P ] [D5] [D6]          │           │  [P ] [Q ] [D5] [D6]     │
  │                          │           │                          │
  │  Can lose any 1 disk     │           │  Can lose any 2 disks    │
  └──────────────────────────┘           └──────────────────────────┘
```

| Mode | Min Disks | Redundancy | Description |
|------|-----------|------------|-------------|
| parity1 | 2 | 1 disk failure | RAID1 (2 disks) or RAID5 (3+) per tier |
| parity2 | 3 | 2 disk failures | RAID6 per tier |

## External Enclosure Support

PoolForge supports pools on external disk enclosures (USB, eSATA, etc.) that may be powered on/off independently:

- Pools can be marked as external during creation (`--external` flag)
- External pools require manual start (`poolforge pool start`) — they won't auto-assemble on boot
- Safe shutdown via `poolforge pool stop` ensures metadata is backed up and arrays are cleanly stopped
- Pool import works with external enclosures — just power on and run `poolforge pool import`
- Dashboard shows operational status (running, offline, safe to power down)

## Performance

Tested on AWS EC2 with 12 EBS volumes (4×10GB + 4×5GB + 4×3GB), 3 RAID5 arrays → LVM → ext4:

```
  Sequential Write   PoolForge ████████████████████████████████████░ 109 MB/s
                     Raw mdadm ████████████████████████████████████░ 110 MB/s

  Sequential Read    PoolForge ████████████████████████████████████████████████████████████░ 262 MB/s
                     Raw mdadm ████████████████████████████████████████████████████████████░ 263 MB/s

  Random 4K Write    PoolForge ████░ 12.5 MB/s
                     Raw mdadm ████░ 12.8 MB/s

  Random 4K Read     PoolForge ████████████░ 49.7 MB/s
                     Raw mdadm ████████████░ 48.8 MB/s
```

| Test | PoolForge | Raw mdadm | Overhead |
|------|-----------|-----------|----------|
| Sequential Write | 109 MB/s | 110 MB/s | <1% |
| Sequential Read | 262 MB/s | 263 MB/s | <1% |
| Random 4K Write | 12.5 MB/s | 12.8 MB/s | ~2% |
| Random 4K Read | 49.7 MB/s | 48.8 MB/s | 0% |

LVM + ext4 adds virtually zero overhead on top of mdadm.

## Architecture

```
  ┌──────────────────────────────────────────────────────────────┐
  │                         CLI / Web UI                          │
  └──────────────┬───────────────────────────────┬───────────────┘
                 │                               │
                 ▼                               ▼
  ┌──────────────────────────┐    ┌──────────────────────────────┐
  │       REST API           │    │       Safety Daemon           │
  │   Web Dashboard (8080)   │    │   SMART, Scrub, Alerts       │
  └──────────────┬───────────┘    └──────────────┬───────────────┘
                 │                               │
                 └───────────────┬───────────────┘
                                 ▼
  ┌──────────────────────────────────────────────────────────────┐
  │                         Engine                                │
  │   Pool creation, tier computation, disk lifecycle,            │
  │   import/migration, start/stop, RAID level selection          │
  └──────────────────────────────┬───────────────────────────────┘
                                 │
                                 ▼
  ┌──────────────────────────────────────────────────────────────┐
  │                      Storage Layer                            │
  │   DiskManager (gdisk)  │  RAIDManager (mdadm)                │
  │   LVMManager (lvm2)    │  FSManager (mkfs/resize2fs)         │
  └──────────────────────────────┬───────────────────────────────┘
                                 │
                                 ▼
  ┌──────────────────────────────────────────────────────────────┐
  │                      Metadata Store                           │
  │   Atomic JSON writes + redundant backup on pool mount        │
  └──────────────────────────────────────────────────────────────┘
```

## System Backup & Migration

Back up your entire PoolForge configuration and restore it on a new machine.

### What's Included

The system backup captures everything needed to rebuild your PoolForge setup:

- Pool metadata (tiers, arrays, LVM config, disk serial numbers and positions)
- Backup job definitions and history
- Sync job definitions and history
- Paired node configurations
- Share and user definitions
- SSH keys for replication
- Server config (`/etc/poolforge.conf`)
- Boot config (`mdadm.conf`)

### Create a Backup

**Dashboard:** Settings tab → System Backup → ⬇ Download Backup (.zip)

**CLI:**
```bash
sudo poolforge system export -o poolforge-backup.zip
```

### Migrate to a New Machine

```bash
# 1. Install PoolForge on the new machine
curl -sSL https://raw.githubusercontent.com/Paul-Cradduck/PoolForge-Releases/main/install.sh | sudo bash

# 2. Copy the backup zip to the new machine and restore
sudo poolforge system restore poolforge-backup.zip

# 3. Connect the same disks (any slot/port order) and import
sudo poolforge pool import

# 4. Start the service
sudo systemctl start poolforge
```

The import matches disks by serial number from the backup metadata — device names and slot positions don't need to match the original machine.

## Requirements

- Ubuntu LTS (20.04, 22.04, 24.04)
- x86_64 architecture
- Root access
- Minimum 2 disks
- Dependencies (installed automatically): `mdadm`, `lvm2`, `smartmontools`, `samba`, `nfs-kernel-server`

## Disclaimer

PoolForge is provided as-is with no warranty of any kind. Use at your own risk. The authors are not responsible for data loss, corruption, or any damages resulting from the use of this software. Always maintain independent backups of critical data.

## License

MIT
