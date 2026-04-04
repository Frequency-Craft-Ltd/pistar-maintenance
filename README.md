# Pi-Star Maintenance Toolkit

Backup, restore, and maintenance scripts for Pi-Star hotspots.

## Scripts

- `scripts/pistar-maint.sh`  
  - Backs up Pi-Star configs
  - Compresses + hashes
  - Optional cloud upload (S3 / B2 / OneDrive via rclone)
  - Local + cloud retention
  - Email notifications
  - Self-update from this GitHub repo
  - Dry-run mode

- `scripts/pistar-restore.sh`  
  - Menu-based cloud backup selection
  - Full / Wi-Fi-only / MMDVMHost-only restore modes
  - Rollback checkpoint
  - Integrity verification
  - Decompression
  - Post-restore validation
  - Dry-run mode

## Basic usage

On Pi-Star:

```bash
sudo mkdir -p /usr/local/bin
sudo curl -fsSL https://raw.githubusercontent.com/Anubis161Killer/pistar-maintenance/main/scripts/pistar-maint.sh -o /usr/local/bin/pistar-maint.sh
sudo curl -fsSL https://raw.githubusercontent.com/Anubis161Killer/pistar-maintenance/main/scripts/pistar-restore.sh -o /usr/local/bin/pistar-restore.sh
sudo chmod +x /usr/local/bin/pistar-*.sh
