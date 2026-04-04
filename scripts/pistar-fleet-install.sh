#!/bin/bash

###############################################################################
# Pi-Star Fleet Installer
# - Installs maintenance + restore scripts
# - Captures fleet identity (callsign / site)
# - Optional cron setup
###############################################################################

set -e

REPO_BASE="https://raw.githubusercontent.com/Anubis161Killer/pistar-maintenance/main/scripts"
ID_FILE="/etc/pistar-fleet-id"

echo "=== Pi-Star Fleet Installer ==="
echo

read -r -p "Fleet ID (e.g. callsign or customer code): " FLEET_ID
read -r -p "Site/Location (e.g. Shack, Repeater, Customer name): " FLEET_SITE

echo
echo "Using:"
echo "  Fleet ID:   $FLEET_ID"
echo "  Site label: $FLEET_SITE"
echo

mkdir -p /usr/local/bin

echo "Downloading pistar-maint.sh..."
curl -fsSL "$REPO_BASE/pistar-maint.sh" -o /usr/local/bin/pistar-maint.sh

echo "Downloading pistar-restore.sh..."
curl -fsSL "$REPO_BASE/pistar-restore.sh" -o /usr/local/bin/pistar-restore.sh

chmod +x /usr/local/bin/pistar-maint.sh
chmod +x /usr/local/bin/pistar-restore.sh

echo "Writing fleet identity to $ID_FILE"
mkdir -p "$(dirname "$ID_FILE")"
cat > "$ID_FILE" <<EOF
FLEET_ID="$FLEET_ID"
FLEET_SITE="$FLEET_SITE"
EOF

echo
read -r -p "Enable nightly maintenance at 3AM? (y/N): " cron_choice

if [[ "$cron_choice" =~ ^[Yy]$ ]]; then
  echo "Adding cron job..."
  (crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/pistar-maint.sh") | crontab -
  echo "Cron job installed."
else
  echo "Skipping cron setup."
fi

echo
echo "Fleet install complete."
echo "You can run:"
echo "  sudo /usr/local/bin/pistar-maint.sh --dry-run"
echo "  sudo /usr/local/bin/pistar-restore.sh"
