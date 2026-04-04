#!/bin/bash

###############################################################################
# Pi-Star Maintenance Bootstrap Installer
# - Installs pistar-maint.sh and pistar-restore.sh
# - Creates /usr/local/bin if needed
# - Makes scripts executable
# - Optional cron scheduling
###############################################################################

set -e

REPO_BASE="https://raw.githubusercontent.com/Anubis161Killer/pistar-maintenance/main/scripts"

echo "=== Pi-Star Maintenance Bootstrap Installer ==="
echo "Installing scripts from: $REPO_BASE"
echo

# Ensure directory exists
mkdir -p /usr/local/bin

# Download scripts
echo "Downloading pistar-maint.sh..."
curl -fsSL "$REPO_BASE/pistar-maint.sh" -o /usr/local/bin/pistar-maint.sh

echo "Downloading pistar-restore.sh..."
curl -fsSL "$REPO_BASE/pistar-restore.sh" -o /usr/local/bin/pistar-restore.sh

# Permissions
chmod +x /usr/local/bin/pistar-maint.sh
chmod +x /usr/local/bin/pistar-restore.sh

echo "Scripts installed to /usr/local/bin"
echo

# Ask about cron
read -r -p "Would you like to enable automatic nightly maintenance at 3AM? (y/N): " cron_choice

if [[ "$cron_choice" =~ ^[Yy]$ ]]; then
    echo "Adding cron job..."
    (crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/pistar-maint.sh") | crontab -
    echo "Cron job installed."
else
    echo "Skipping cron setup."
fi

echo
echo "Installation complete!"
echo "Run maintenance manually with:"
echo "  sudo pistar-maint.sh"
echo
echo "Run restore with:"
echo "  sudo pistar-restore.sh"
echo
echo "Done."
