#!/bin/bash

###############################################################################
# Pi-Star Maintenance Bootstrap Installer
# Frequency Craft Ltd
#
# - Installs pistar-maint.sh, pistar-restore.sh, pistar-fleet-install.sh
# - Creates /usr/local/bin if needed
# - Captures fleet identity (ID, site, GPS)
# - Writes /etc/pistar-fleet-id
# - Optional nightly cron job
# - Dependency checks
###############################################################################

set -e

REPO_BASE="https://raw.githubusercontent.com/Frequency-Craft-Ltd/pistar-maintenance/main/scripts"
ID_FILE="/etc/pistar-fleet-id"

echo "=============================================================="
echo "     Frequency Craft Ltd - Pi-Star Bootstrap Installer"
echo "=============================================================="
echo

# -----------------------------
# Dependency checks
# -----------------------------
echo "Checking dependencies..."

if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl is not installed. Install it with:"
    echo "sudo apt-get install curl"
    exit 1
fi

if ! command -v rclone >/dev/null 2>&1; then
    echo "WARNING: rclone is not installed."
    echo "Cloud uploads and fleet status sync will not work until installed."
    echo
fi

echo "Dependencies OK."
echo

# -----------------------------
# Fleet identity capture
# -----------------------------
echo "Enter fleet identity information:"
echo

read -r -p "Fleet ID (callsign/customer code): " FLEET_ID
read -r -p "Site/Location (e.g. Shack, Repeater, Customer): " FLEET_SITE
read -r -p "Latitude (e.g. 52.5200): " FLEET_LAT
read -r -p "Longitude (e.g. -1.4650): " FLEET_LON

echo
echo "Writing fleet identity to $ID_FILE..."
mkdir -p "$(dirname "$ID_FILE")"

cat > "$ID_FILE" <<EOF
FLEET_ID="$FLEET_ID"
FLEET_SITE="$FLEET_SITE"
FLEET_LAT="$FLEET_LAT"
FLEET_LON="$FLEET_LON"
EOF

echo "Fleet identity saved."
echo

# -----------------------------
# Install scripts
# -----------------------------
echo "Installing maintenance scripts into /usr/local/bin..."
mkdir -p /usr/local/bin

echo "Downloading pistar-maint.sh..."
curl -fsSL "$REPO_BASE/pistar-maint.sh" -o /usr/local/bin/pistar-maint.sh

echo "Downloading pistar-restore.sh..."
curl -fsSL "$REPO_BASE/pistar-restore.sh" -o /usr/local/bin/pistar-restore.sh

echo "Downloading pistar-fleet-install.sh..."
curl -fsSL "$REPO_BASE/pistar-fleet-install.sh" -o /usr/local/bin/pistar-fleet-install.sh

chmod +x /usr/local/bin/pistar-*.sh

echo "Scripts installed."
echo

# -----------------------------
# Cron job setup
# -----------------------------
read -r -p "Enable nightly maintenance at 3AM? (y/N): " cron_choice

if [[ "$cron_choice" =~ ^[Yy]$ ]]; then
    echo "Installing cron job..."
    (crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/pistar-maint.sh") | crontab -
    echo "Cron job installed."
else
    echo "Skipping cron setup."
fi

echo
echo "=============================================================="
echo " Installation Complete"
echo "=============================================================="
echo
echo "Maintenance script:"
echo "  sudo /usr/local/bin/pistar-maint.sh"
echo
echo "Restore script:"
echo "  sudo /usr/local/bin/pistar-restore.sh"
echo
echo "Fleet identity file:"
echo "  $ID_FILE"
echo
echo "To re-run the installer:"
echo "  sudo bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Frequency-Craft-Ltd/pistar-maintenance/main/scripts/bootstrap.sh)\""
echo
echo "Done."
