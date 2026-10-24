#!/bin/bash

# Ensure the script is run with root privileges
if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run this script with root privileges (sudo)."
  exit 1
fi

PROJECT_DIR="/root/shammat"
SERVICE_NAME="shammat"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

echo "----------------------------------------"
echo "[+] Removing Shammat Bot Service Only..."
echo "----------------------------------------"

# 1. Stop and disable the systemd service
if systemctl list-unit-files | grep -q "${SERVICE_NAME}.service"; then
    echo "[+] Stopping ${SERVICE_NAME} service..."
    systemctl stop ${SERVICE_NAME}
    
    echo "[+] Disabling ${SERVICE_NAME} service..."
    systemctl disable ${SERVICE_NAME}
    
    echo "[+] Removing service file from systemd..."
    rm -f "${SERVICE_FILE}"
    
    systemctl daemon-reload
    systemctl reset-failed
    echo "[✓] Systemd service removed successfully."
else
    echo "[i] Systemd service not found, skipping..."
fi
# 2. Remove Cron Job for backups
echo "[+] Removing backup cron job..."

BACKUP_SCRIPT="/root/shammat/backup.sh"
CURRENT_CRONTAB="$(crontab -l 2>/dev/null || true)"

if echo "$CURRENT_CRONTAB" | grep -Fq "$BACKUP_SCRIPT"; then
    printf '%s\n' "$CURRENT_CRONTAB" \
        | grep -Fv "$BACKUP_SCRIPT" \
        | crontab -

    echo "[✓] Backup cron job removed successfully."
else
    echo "[i] Backup cron job not found, skipping..."
fi