<div align="center">

# 🦀 Rust Wipe Manager

### Production-ready automation toolkit for Rust game servers running LinuxGSM

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash](https://img.shields.io/badge/Bash-4EAA25?style=flat&logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-E95420?style=flat&logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![systemd](https://img.shields.io/badge/systemd-000000?style=flat&logo=linux&logoColor=white)](https://systemd.io/)
[![LinuxGSM](https://img.shields.io/badge/LinuxGSM-0066CC?style=flat&logo=linux&logoColor=white)](https://linuxgsm.com/)
[![Telegram](https://img.shields.io/badge/Telegram-26A5E4?style=flat&logo=telegram&logoColor=white)](https://telegram.org/)
[![Rust Game](https://img.shields.io/badge/Rust-CD412B?style=flat&logo=rust&logoColor=white)](https://rust.facepunch.com/)

**Daily restarts • Smart Full Wipe automation • Update detection • Telegram alerts • Self-healing**

[Features](#-features) • [How it works](#-how-it-works) • [Installation](#-installation) • [Configuration](#-configuration) • [Troubleshooting](#-troubleshooting)

</div>

---

## 📖 Overview

**Rust Wipe Manager** is a complete automation toolkit for [Rust](https://rust.facepunch.com/) game servers running on [LinuxGSM](https://linuxgsm.com/). It handles the boring parts of running a Rust server so you don't have to: daily restarts, monthly Full Wipes synced with Facepunch's update cycle, server crash recovery, OS updates, and detailed Telegram notifications at every step.

The toolkit was built and battle-tested on a real production server (`bzod.ru`) running on **Ubuntu 24.04 LTS** + **Proxmox VM** + **LinuxGSM** + **uMod (Oxide)**.

## ✨ Features

### 🔄 Smart daily restarts
- Player warning via RCON with countdown (configurable, default 30 minutes)
- Graceful shutdown with fallback to `systemctl stop` if hung
- Automatic Rust + Oxide updates during restart
- OS package updates (`unattended-upgrade`) in the same window, while the server is down
- Reboots the VM instead of starting the server when the OS asks for it (the systemd unit starts Rust on boot)
- One-time power-off flag (`.poweroff-once`) for host-side maintenance
- Skips itself on Full Wipe day to avoid conflict

### 🔥 Automatic Full Wipe on the first Thursday of every month
- Syncs with Facepunch's official patch cadence (19:00 London time)
- **Waits for the actual update to appear in Steam** before wiping (no risk of wiping on old version)
- Polls Steam every 2 minutes for up to 2 hours
- Aborts wipe with critical Telegram alert if update doesn't appear in time
- Manual `fullwipe-now` does **not** wait: it updates if an update is available and wipes either way
- Fresh random map seed on every Full Wipe (done by LinuxGSM when `seed` is empty, see [Map seed](#-map-seed))
- Backs up Oxide `Managed/` directory before update

### 🛡️ systemd integration
- Auto-start on machine boot
- Auto-restart on crash (via LGSM monitor)
- Logs accessible via `journalctl -u rustserver`
- Clean `start`/`stop`/`restart` interface

### 📱 Telegram notifications at every step
- Restart started / RCON sent / server stopped / update done / server back up
- After any VM boot: server is up (with kernel version) or failed to start (`post-boot`)
- Three log levels: `full` / `success_error` / `error_only`
- Critical alerts on failures (timeout, update error, server didn't start)

### 🔐 Security-conscious
- All secrets stored in a separate `.secrets.env` file with `chmod 600`
- Sudo restricted to a short list of commands: `systemctl` for the service, `apt-get update -qq`, `unattended-upgrade`, `reboot`, `poweroff`
- No credentials in the main script — safe to publish

## 🏗️ Architecture

```mermaid
graph TB
    subgraph "🖥️ Proxmox Host"
        subgraph "🐧 Ubuntu VM"
            CRON[⏰ cron]
            SYSTEMD[⚙️ systemd]
            MANAGER[📜 manager.sh]
            LGSM[🎮 LinuxGSM]
            RUST[🦀 RustDedicated]
            OXIDE[🔧 Oxide/uMod]
            OS[📦 OS packages]
        end
    end

    TG[📱 Telegram Bot API]
    STEAM[☁️ Steam / Facepunch]
    PLAYERS[👥 Players]

    CRON -->|"04:30 daily"| MANAGER
    CRON -->|"19:00 Thursdays"| MANAGER
    CRON -->|"@reboot: post-boot"| MANAGER
    SYSTEMD -->|"on boot / crash"| LGSM
    MANAGER -->|"start/stop"| SYSTEMD
    MANAGER -->|"RCON commands"| RUST
    MANAGER -->|"check-update"| LGSM
    MANAGER -->|"unattended-upgrade, reboot"| OS
    MANAGER -->|"alerts"| TG
    LGSM -->|"download updates"| STEAM
    LGSM -->|"manages"| RUST
    RUST -->|"hosts"| OXIDE
    PLAYERS -.->|"connect"| RUST

    style MANAGER fill:#CD412B,color:#fff
    style RUST fill:#CD412B,color:#fff
    style TG fill:#26A5E4,color:#fff
    style SYSTEMD fill:#000,color:#fff
```

## 🎯 How it works

### Daily restart flow

```mermaid
sequenceDiagram
    participant C as ⏰ cron (04:30 MSK)
    participant M as 📜 manager.sh
    participant R as 🦀 Rust Server
    participant S as ⚙️ systemd
    participant T as 📱 Telegram

    C->>M: trigger "restart" mode
    M->>M: Is today first Thursday?
    alt Yes (Full Wipe day)
        M->>T: "Skipping daily restart"
        M-->>C: exit 0
    else No (regular day)
        M->>T: "Daily restart started"
        M->>R: RCON "restart 1800 server_restart"
        Note over R: Players see countdown<br/>30 minutes
        R->>R: Players warned, countdown
        M->>M: sleep 1800s
        R->>S: server stopped
        M->>T: "Server stopped"
        M->>M: ./rustserver update
        M->>M: ./rustserver mods-update
        M->>T: "Updates done"
        M->>M: apt-get update + unattended-upgrade
        M->>T: "OS updates installed"
        alt .poweroff-once flag exists
            M->>T: "VM powering off for host maintenance"
            M->>S: sudo poweroff (the host starts the VM again)
        else /var/run/reboot-required exists
            M->>T: "OS update needs a reboot"
            M->>S: sudo reboot (Rust starts on boot)
        else Nothing pending
            M->>S: systemctl start rustserver
            S->>R: server starts
            M->>M: poll for RustDedicated process
            M->>T: "✅ Restart complete"
        end
    end
```

The OS maintenance steps (`update_system`, `reboot_if_required`) run after the Rust/Oxide updates, while the server is down:

- **OS updates** — `apt-get update -qq` + `unattended-upgrade`, controlled by `SYSTEM_UPDATE_ENABLED`. For updates to land only in this window, turn off the stock apt timer (see Installation, step 4).
- **Reboot** — controlled by `REBOOT_IF_REQUIRED`. If `/var/run/reboot-required` exists, the VM reboots instead of starting the server; the systemd unit starts Rust on boot.
- **One-time power-off** — `touch ~/rust_server/.poweroff-once` makes the next daily restart power the VM off instead of starting the server (for host-side maintenance, e.g. Proxmox `qm enroll-efi-keys <vmid>`, which needs the VM shut down). The flag is deleted when used, and the host has to start the VM again.

### Post-boot report

```mermaid
sequenceDiagram
    participant C as ⏰ cron (@reboot)
    participant M as 📜 manager.sh
    participant R as 🦀 Rust Server
    participant T as 📱 Telegram

    C->>M: trigger "post-boot" mode
    loop Every 10 seconds (max SERVER_START_TIMEOUT)
        M->>R: is RustDedicated running?
    end
    alt Process found
        M->>T: "✅ VM booted, server is up (kernel version)"
    else Timeout
        M->>T: "❌ VM booted, but the server did not start"
    end
```

### Full Wipe flow

```mermaid
sequenceDiagram
    participant C as ⏰ cron (Thursdays 19:00)
    participant M as 📜 manager.sh
    participant FP as ☁️ Facepunch/Steam
    participant R as 🦀 Rust Server
    participant T as 📱 Telegram

    C->>M: trigger "fullwipe" mode
    M->>M: Is today first Thursday?
    alt No
        M-->>C: exit 0
    else Yes
        M->>M: Calculate 19:00 London time<br/>(handles BST/GMT auto)
        M->>M: sleep until T-30min
        M->>T: "🔥 Full Wipe preparation started"
        M->>R: RCON "restart 600 FULL_WIPE_UPDATE"
        Note over R: 10-minute countdown
        M->>M: sleep 600s
        R->>R: server stopped

        Note over M,FP: Manual "fullwipe-now" skips the wait loop<br/>(updates if available, wipes either way)
        loop Every 2 minutes (max 2h)
            M->>FP: check-update (compare builds)
            alt Update available
                M->>T: "🎉 Update detected!"
            else No update yet
                M->>M: sleep 120s
            end
        end

        alt Timeout (no update in 2h)
            M->>T: "🚨 TIMEOUT! Manual intervention needed"
            M-->>C: exit 1
        else Update found
            M->>M: backup Oxide Managed/
            M->>FP: ./rustserver update
            M->>FP: ./rustserver mods-update
            M->>R: ./rustserver full-wipe
            Note over R: Map + blueprints<br/>wiped clean
            M->>R: systemctl start rustserver
            M->>T: "🎉 New wipe is live!"
        end
    end
```

> 💡 The wait loop belongs to the scheduled `fullwipe` (first Thursday). A manual `fullwipe-now` does not wait for Facepunch: it runs `./rustserver update` (which updates only if a new build is out) and then wipes either way.

## 🛠️ Tech Stack

| Component | Purpose |
|---|---|
| ![Bash](https://img.shields.io/badge/-Bash-4EAA25?logo=gnubash&logoColor=white) | Main scripting language |
| ![Ubuntu](https://img.shields.io/badge/-Ubuntu_24.04-E95420?logo=ubuntu&logoColor=white) | Host OS |
| ![systemd](https://img.shields.io/badge/-systemd-000000?logo=linux&logoColor=white) | Service management & auto-start |
| ![LinuxGSM](https://img.shields.io/badge/-LinuxGSM-0066CC?logo=linux&logoColor=white) | Game server wrapper |
| ![Rust](https://img.shields.io/badge/-Rust_Game-CD412B?logo=rust&logoColor=white) | The game itself |
| ![Oxide](https://img.shields.io/badge/-uMod/Oxide-7B68EE) | Plugin framework |
| ![cron](https://img.shields.io/badge/-cron-008000) | Task scheduling |
| ![rcon-cli](https://img.shields.io/badge/-rcon--cli-FF6B6B) | RCON communication |
| ![Telegram](https://img.shields.io/badge/-Telegram_Bot_API-26A5E4?logo=telegram&logoColor=white) | Notifications |

## 📋 Requirements

- **OS**: Ubuntu 24.04 LTS (or any modern Debian-based distro with systemd)
- **LinuxGSM** installed and `rustserver` configured at `~/rustserver`
- **Rust dedicated server** running via LGSM
- **systemd** (built into modern distros)
- **rcon-cli** by gorcon: [github.com/gorcon/rcon-cli](https://github.com/gorcon/rcon-cli)
- **Telegram bot** (optional but recommended) — get token from [@BotFather](https://t.me/BotFather)
- **sudo** rights for the user running the server (limited to `systemctl`, `apt-get update -qq`, `unattended-upgrade`, `reboot`, `poweroff`)

## 🚀 Installation

### 1️⃣ Install LinuxGSM and Rust server

```bash
curl -Lo linuxgsm.sh https://linuxgsm.sh && chmod +x linuxgsm.sh && bash linuxgsm.sh rustserver
./rustserver auto-install
```

### 2️⃣ Install rcon-cli

```bash
cd ~
wget https://github.com/gorcon/rcon-cli/releases/download/v0.10.3/rcon-0.10.3-amd64_linux.tar.gz
tar -xzf rcon-0.10.3-amd64_linux.tar.gz
rm rcon-0.10.3-amd64_linux.tar.gz
```

### 3️⃣ Set up systemd service

Create `/etc/systemd/system/rustserver.service`:

```ini
[Unit]
Description=Rust Server (LinuxGSM)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=YOUR_USERNAME
Group=YOUR_USERNAME
WorkingDirectory=/home/YOUR_USERNAME
ExecStart=/home/YOUR_USERNAME/rustserver start
ExecStop=/home/YOUR_USERNAME/rustserver stop
TimeoutStartSec=600
TimeoutStopSec=300

[Install]
WantedBy=multi-user.target
```

Enable and start:
```bash
sudo systemctl daemon-reload
sudo systemctl enable rustserver
sudo systemctl start rustserver
```

> ⚠️ **Why `Type=oneshot` and not `Type=forking`?** LinuxGSM uses tmux internally and detaches the process. With `Type=forking` systemd loses track of the actual server process. `Type=oneshot` + `RemainAfterExit=yes` is the cleanest solution that works reliably with LGSM.

### 4️⃣ Set up sudoers (passwordless systemctl, apt, reboot)

```bash
echo 'YOUR_USERNAME ALL=(root) NOPASSWD: /usr/bin/systemctl start rustserver, /usr/bin/systemctl stop rustserver, /usr/bin/systemctl restart rustserver, /usr/bin/apt-get update -qq, /usr/bin/unattended-upgrade, /usr/sbin/reboot, /usr/sbin/poweroff' | sudo tee /etc/sudoers.d/YOUR_USERNAME-rustserver
sudo chmod 440 /etc/sudoers.d/YOUR_USERNAME-rustserver
```

**Recommended:** disable the stock unattended-upgrade timer so OS upgrades land only in the daily restart window, while the server is down. In `/etc/apt/apt.conf.d/20auto-upgrades` keep the package list refresh and turn off the periodic upgrade:

```
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "0";
```

### 5️⃣ Clone this repo

```bash
mkdir -p ~/rust_server
cd ~/rust_server
wget https://raw.githubusercontent.com/wobujidao/rust-wipe-manager/main/manager.sh
wget https://raw.githubusercontent.com/wobujidao/rust-wipe-manager/main/config.env.example -O config.env
wget https://raw.githubusercontent.com/wobujidao/rust-wipe-manager/main/secrets.env.example -O .secrets.env
chmod +x manager.sh
chmod 600 .secrets.env
```

### 6️⃣ Configure secrets and config

Edit `.secrets.env` with your real values:
```bash
nano ~/rust_server/.secrets.env
```

```env
TELEGRAM_BOT_TOKEN="123456789:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
TELEGRAM_CHAT_ID="-1001234567890"
RCON_PASS="your_rcon_password_here"
```

Edit `config.env` to match your paths and preferences:
```bash
nano ~/rust_server/config.env
```

### 7️⃣ Test it

```bash
~/rust_server/manager.sh test-telegram
~/rust_server/manager.sh check-update
```

You should get a Telegram message and see version info from Steam.

### 8️⃣ Add cron tasks

```bash
crontab -e
```

Add:
```cron
30 4 * * * /home/YOUR_USERNAME/rust_server/manager.sh restart >> /home/YOUR_USERNAME/rust_server/logs/cron.log 2>&1
0 19 * * 4 /home/YOUR_USERNAME/rust_server/manager.sh fullwipe >> /home/YOUR_USERNAME/rust_server/logs/cron.log 2>&1
@reboot /home/YOUR_USERNAME/rust_server/manager.sh post-boot >> /home/YOUR_USERNAME/rust_server/logs/cron.log 2>&1
```

> 💡 The Full Wipe task runs **every Thursday** at 19:00, but the script itself checks if today is the first Thursday of the month and exits immediately on other Thursdays. On the first Thursday it sleeps until (`FULLWIPE_LONDON_HOUR` in London time − `FULLWIPE_PRE_WAIT_MINUTES`) and starts preparing then.

> 🕒 Cron times are in the **VM's local timezone**.

> 📣 The `@reboot` entry runs `post-boot` after every VM boot (including the reboots and power cycles triggered by the daily restart) and reports to Telegram whether the server came up.

## ⚙️ Configuration

All settings live in `config.env`. The most important ones:

| Parameter | Default | Description |
|---|---|---|
| `DAILY_RESTART_COUNTDOWN` | `1800` | Countdown before daily restart (seconds) |
| `DAILY_RESTART_UPDATE_RUST` | `true` | Update Rust during daily restart |
| `DAILY_RESTART_UPDATE_OXIDE` | `true` | Update Oxide during daily restart |
| `FULLWIPE_COUNTDOWN` | `600` | Countdown before Full Wipe stop (seconds) |
| `FULLWIPE_LONDON_HOUR` | `19` | Hour in London time when Facepunch releases updates |
| `FULLWIPE_PRE_WAIT_MINUTES` | `30` | Start preparing this many minutes before update |
| `FULLWIPE_UPDATE_WAIT_MAX` | `7200` | Maximum time the scheduled `fullwipe` waits for the Steam update (seconds); `fullwipe-now` does not wait |
| `FULLWIPE_UPDATE_CHECK_INTERVAL` | `120` | Check Steam every N seconds |
| `SKIP_DAILY_RESTART_ON_FULLWIPE_DAY` | `true` | Skip daily restart on Full Wipe Thursday |
| `OXIDE_BACKUP_BEFORE_UPDATE` | `true` | Backup `Managed/` before Oxide update |
| `SYSTEM_UPDATE_ENABLED` | `true` | Run `apt-get update` + `unattended-upgrade` in the daily restart window (server down) |
| `REBOOT_IF_REQUIRED` | `true` | If the OS needs a reboot, reboot the VM instead of starting the server |
| `SERVER_START_TIMEOUT` | `600` | Max time to wait for RustDedicated process (also used by `post-boot`) |
| `ENABLE_TELEGRAM` | `true` | Enable Telegram notifications |
| `TELEGRAM_LOG_LEVEL` | `full` | `full` / `success_error` / `error_only` |

### 🌱 Map seed

The manager does not touch the seed itself — LinuxGSM does. If `seed=""` in `lgsm/config-lgsm/rustserver/rustserver.cfg`, LGSM's `full-wipe` writes a new random seed to `lgsm/data/rustserver-seed.txt`, and the next start uses it.

- LGSM only wipes (and rotates the seed) when a `.map`/`.sav` file exists; otherwise it prints "Wipe not required" and the seed stays.
- A forced Facepunch update alone wipes the map (save version bump) but keeps the same seed, so the terrain repeats. Only an LGSM `full-wipe` changes the seed.

## 🎮 Commands

```bash
# Daily restart (with auto-skip on Full Wipe day), plus OS updates / reboot
./manager.sh restart

# Full Wipe (only runs if today is first Thursday; waits for the Facepunch update)
./manager.sh fullwipe

# Manual Full Wipe — bypasses date check, does not wait for a Facepunch
# update (updates if one is available, wipes either way) (USE WITH CAUTION)
./manager.sh fullwipe-now

# Report the server state after a VM boot (for the @reboot cron entry)
./manager.sh post-boot

# Test Telegram notifications
./manager.sh test-telegram

# Check if Steam has a Rust update
./manager.sh check-update
```

One-time power-off at the next daily restart (host-side maintenance):
```bash
touch ~/rust_server/.poweroff-once
```
The VM powers off instead of starting the server, the flag is deleted when used, and the host has to start the VM again.

## 📁 Project structure

```
rust_server/
├── manager.sh           # Main script
├── config.env           # Configuration (paths, timings, flags)
├── .secrets.env         # Telegram token, RCON password (chmod 600)
├── .poweroff-once       # Optional one-time power-off flag (deleted when used)
└── logs/
    ├── manager-YYYYMMDD.log
    └── cron.log
```

## 🔧 Troubleshooting

### Server doesn't auto-start after reboot
Check the systemd unit:
```bash
sudo systemctl status rustserver
sudo systemctl is-enabled rustserver
journalctl -u rustserver -n 50
```
Make sure it's `enabled` and `Type=oneshot` (not `forking`).

### `sudo: a password is required` from cron
The `sudoers.d/` rule wasn't applied correctly. Verify:
```bash
sudo -n systemctl status rustserver
```
Should show status without asking for a password. `sudo -n -l` lists the allowed commands — it must include `apt-get update -qq`, `unattended-upgrade`, `reboot` and `poweroff` too, otherwise the OS maintenance step fails with an "OS update error" alert.

### `find: Failed to restore initial working directory`
LinuxGSM's `find` calls fail when the inherited working directory is unreadable — typically when running via `sudo -u YOUR_USERNAME` from another user's home. `manager.sh` now `cd`s into its own directory at startup, so this is fixed for the script. For manual LGSM commands, run them as the server user from its home:
```bash
sudo -iu YOUR_USERNAME
./rustserver details
```

### VM powered off after the daily restart and did not come back
That is the `.poweroff-once` flag at work: the VM powers off by design so the host can do maintenance, and the host has to start it again. The flag is deleted when used, so the next daily restart is normal.

### Full Wipe ran but server is on old version
The `wait_for_rust_update` loop should prevent this for the scheduled `fullwipe`. A manual `fullwipe-now` does not wait, so it wipes on the old version if Facepunch has not released the update yet. If the scheduled run did it anyway:
1. Check `~/rust_server/logs/manager-*.log` for the wait phase
2. Verify `check-update` returns the correct build numbers manually
3. Increase `FULLWIPE_UPDATE_WAIT_MAX` if Facepunch was extra late

### Oxide won't load after Full Wipe
Oxide releases sometimes lag behind Rust releases by 30-90 minutes. If `mods-update` ran too early, you may have an incompatible version. Solutions:
- Wait 30 minutes and run `~/rustserver mods-update` manually, then restart
- Restore from auto-backup: `~/serverfiles/RustDedicated_Data/Managed.backup-YYYY-MM-DD/`

### Telegram messages not arriving
```bash
~/rust_server/manager.sh test-telegram
```
If nothing arrives, verify:
- Bot token is correct in `.secrets.env`
- Chat ID is correct (negative for groups, positive for direct chats)
- Bot has been added to the group/channel
- `curl https://api.telegram.org/botYOUR_TOKEN/getMe` returns `"ok":true`

## 🗺️ Roadmap

- [ ] Discord webhook support (alongside Telegram)
- [ ] Web dashboard for log viewing
- [x] Map seed rotation automation — done by LinuxGSM, see [Map seed](#-map-seed)
- [ ] Integration with `BattleMetrics` API for player count alerts
- [ ] Plugin update notifications (when popular plugins get updates)
- [ ] Multi-server support (one manager, multiple servers)

## 🤝 Contributing

PRs and issues welcome. This project is built for real production use, so please test changes against a real LGSM Rust server before submitting.

## 📜 License

MIT — do whatever you want with this code, just don't blame me if your server explodes.

## 🙏 Credits

- [LinuxGSM](https://linuxgsm.com/) — the unsung hero of game server hosting
- [gorcon/rcon-cli](https://github.com/gorcon/rcon-cli) — clean RCON client
- [Facepunch Studios](https://facepunch.com/) — for making Rust
- [uMod / Oxide](https://umod.org/) — for the plugin ecosystem

---

<div align="center">


If this saved you time, ⭐ star the repo!

</div>
