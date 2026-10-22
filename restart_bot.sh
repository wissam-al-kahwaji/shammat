#!/bin/bash

# Ensure the script is run with root privileges
if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run this script with root privileges (sudo)."
  exit 1
fi

echo "[+] Reloading systemd daemon..."
systemctl daemon-reload

echo "[+] Restarting shammat service..."
systemctl restart shammat

echo "[+] Checking service status..."
sleep 2
if systemctl is-active --quiet shammat; then
    echo "[✓] Shammat bot restarted and is running successfully!"
else
    echo "[!] Warning: Shammat service failed to start properly. Check logs using: journalctl -u shammat -n 50"
fi