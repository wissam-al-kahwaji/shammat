#!/bin/bash

# Ensure the script is run with root privileges
if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run this script with root privileges (sudo)."
  exit 1
fi

echo "[+] Starting Telegram Bot setup..."

# 1. Dynamic Language Selection from 'language' directory
LANG_BASE_DIR="/root/shammat/language"

if [ ! -d "$LANG_BASE_DIR" ]; then
    echo "[-] Error: Directory '$LANG_BASE_DIR' does not exist!"
    echo "[-] Make sure you have a 'language' folder containing language subfolders (e.g., ar, en)."
    exit 1
fi

echo "=================================================="
echo "           Shammat Bot Language Selection         "
echo "=================================================="

# Read available language folders dynamically
LANGS=($(find "$LANG_BASE_DIR" -mindepth 1 -maxdepth 1 -type d | xargs -n 1 basename))

if [ ${#LANGS[@]} -eq 0 ]; then
    echo "[-] Error: No language folders found inside '$LANG_BASE_DIR'!"
    exit 1
fi

for i in "${!LANGS[@]}"; do
    echo "$((i+1))) ${LANGS[$i]}"
done
echo "--------------------------------------------------"

read -p "Select language choice [1-${#LANGS[@]}]: " LANG_CHOICE

# Validate input and get selected language directory name
INDEX=$((LANG_CHOICE-1))
if [[ "$INDEX" -ge 0 && "$INDEX" -lt "${#LANGS[@]}" ]]; then
    SELECTED_LANG="${LANGS[$INDEX]}"
else
    SELECTED_LANG="${LANGS[0]}"
    echo "[i] Invalid selection, defaulting to: $SELECTED_LANG"
fi

SOURCE_LANG_DIR="$LANG_BASE_DIR/$SELECTED_LANG"
echo "[+] Selected Language: $SELECTED_LANG ($SOURCE_LANG_DIR)"

# 2. Check if responses.json and texts.json exist in the selected language folder
if [ ! -f "$SOURCE_LANG_DIR/responses.json" ] || [ ! -f "$SOURCE_LANG_DIR/texts.json" ]; then
    echo "[-] Error: Missing 'responses.json' or 'texts.json' inside '$SOURCE_LANG_DIR'!"
    exit 1
fi

# 3. Setup project directory and clean old language files
PROJECT_DIR="/root/shammat"
mkdir -p "$PROJECT_DIR"

echo "[+] Cleaning old configuration files from $PROJECT_DIR..."
rm -f "$PROJECT_DIR/responses.json"
rm -f "$PROJECT_DIR/texts.json"

echo "[+] Copying new language files ($SELECTED_LANG) to $PROJECT_DIR..."
cp "$SOURCE_LANG_DIR/responses.json" "$PROJECT_DIR/responses.json"
cp "$SOURCE_LANG_DIR/texts.json" "$PROJECT_DIR/texts.json"

# 4. Prompt for Telegram Bot Credentials (Token & Chat ID)
echo "----------------------------------------"
echo "[?] Please enter your Telegram Bot details:"
echo "----------------------------------------"
read -p "Enter Telegram Bot Token: " BOT_TOKEN
read -p "Enter Telegram Chat ID: " CHAT_ID

# Save credentials to a configuration file inside the project directory
cat <<EOF > "$PROJECT_DIR/.telegram.env"
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
EOF

echo "[✓] Bot configuration saved successfully!"

# 5. Setup Systemd Service using your exact template configuration
BOT_SERVICE_PATH="/etc/systemd/system/shammat.service"

echo "[+] Configuring systemd service (shammat.service)..."

cat <<EOF > "$BOT_SERVICE_PATH"
[Unit]
Description=Minecraft + Telegram bot ($SELECTED_LANG)
After=network-online.target docker.service
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 -u $PROJECT_DIR/shammat.py
Restart=always
RestartSec=1
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and restart the service
systemctl daemon-reload
systemctl enable shammat.service
systemctl restart shammat.service

echo "=================================================="
echo "[✓] Shammat Bot ($SELECTED_LANG) installed and started successfully!"
echo "[i] Service name: shammat.service"
echo "[i] Working directory: $PROJECT_DIR"
echo "=================================================="

# 6. Schedule Daily Backup at 07:00 AM
echo "[+] Configuring daily backup cron job..."

BACKUP_SCRIPT="/root/shammat/backup.sh"
CRON_JOB="0 7 * * * /bin/bash $BACKUP_SCRIPT >> /var/log/backup.log 2>&1"

if [ ! -f "$BACKUP_SCRIPT" ]; then
    echo "[-] Warning: $BACKUP_SCRIPT not found. Skipping cron setup."
else
    chmod +x "$BACKUP_SCRIPT"

    (crontab -l 2>/dev/null | grep -Fv "$BACKUP_SCRIPT"; echo "$CRON_JOB") | crontab -

    echo "[✓] Daily backup scheduled at 07:00 AM."
fi
