# Virtualizor Bandwidth Carry-Over Manager

A user-friendly, menu-driven command-line tool to automate the process of resetting and carrying over unused bandwidth for Virtualizor-based VPSs. This script allows you to manage the entire process, from configuration to manual runs and cron job automation, through a simple interface.

**Created by LivingGOD**

<img width="822" height="451" alt="image_2025-07-28_00-34-27" src="https://github.com/user-attachments/assets/f3b14d29-bd32-4587-b139-75757c1c1bc8" />

## ✨ Features

* **All-in-One Interface:** Manage configuration, manual resets, and automation from a single command.

* **Dedicated Configuration:** Safely stores your API credentials in `/etc/vps_manager.conf`.

* **Intelligent Carry-Over:** Calculates unused bandwidth and applies it as the new limit for the next billing cycle.

* **Flexible Targeting:** Reset bandwidth for a single VPS or all servers on the node.

* **Full Automation:** Easily set up, view, and remove daily or monthly cron jobs.

* **Safe & Robust:** Includes dependency checks, robust error handling, and detailed logging to `/root/reset_band.log` (override with `DIAG_DIR`).

## 🚀 Installation (Git Clone)

This keeps the script updateable via `git pull`.

1. Clone the repo:
```
git clone https://github.com/KiaTheRandomGuy/virtualizor-bwreset.git /root/virtualizor-bwreset
```

2. Make the script executable:
```
chmod +x /root/virtualizor-bwreset/reset_band.sh
```

3. Create a stable command path (optional but recommended):
```
ln -sf /root/virtualizor-bwreset/reset_band.sh /root/vps_manager.sh
```

## ⚙️ First-Time Setup

The script uses a configuration file at `/etc/vps_manager.conf`. You can create it manually (or let the script create it on first run) so updates to the repo never overwrite your settings.

1. Create or open the config: `nano /etc/vps_manager.conf`

2. Set your values:
```
HOST="your-virtualizor-host"
KEY="your-api-key"
PASS="your-api-pass"
API_BASE=""
PARALLEL_JOBS=5
```

3. Run the script: `/root/vps_manager.sh`

Your credentials are now saved, and you can proceed to use the other script features.

## 🔁 Update

```
git -C /root/virtualizor-bwreset pull
```

## 🔧 Usage

* **Configure:** Edit your API credentials.

* **Manual Reset:** Immediately run the bandwidth carry-over for all servers or a specific VPS ID. The results of the operation will be displayed on screen.

* **Manage Automation:**

  * Enable a daily or monthly cron job.

  * Disable and remove any existing cron job set by this script.

  * View the current status of the cron job.

  * Manually edit your crontab file using the `nano` editor.

## 📝 Logging

The script generates two log files in the `/root/` directory by default (set `DIAG_DIR` to change the location):

* `/root/reset_band.log`: A detailed, verbose log of all actions.

* `/root/reset_band_changes.log`: A clean audit log that only contains entries for successfully processed servers.
## 📜 License

This project is licensed under the Apache-2.0 License.
