#!/bin/bash
set -euo pipefail

# ===== Settings =====
SERVER_DIR="/root/minecraft"
BACKUP_DIR="/root/backups"
KEEP=5
LOCK="/tmp/mc_backup.lock"
TG_ENV="/root/shammat/.telegram.env"
VOLUME_SIZE="45m"
COMPRESSION=5
WARN_MINUTES=15
# ====================

# Emergency mode: skip the warning and the waiting period
INSTANT=false
[ "${1:-}" = "--now" ] && INSTANT=true

log() { echo "[$(date '+%F %T')] $*"; }

command -v 7z > /dev/null || { echo "7z not found. Run: apt install -y p7zip-full"; exit 1; }

# Load Telegram credentials
source "$TG_ENV"

tg_message() {
    curl -s --max-time 30 "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="$CHAT_ID" \
        -d parse_mode="HTML" \
        --data-urlencode text="$1" > /dev/null || log "Failed to send Telegram message"
}

tg_file() {
    local file="$1" caption="$2"
    curl -s --max-time 900 \
        -F chat_id="$CHAT_ID" \
        -F document=@"$file" \
        -F caption="$caption" \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument" | grep -q '"ok":true'
}

# Prevent two instances from running at the same time
exec 9>"$LOCK"
flock -n 9 || { log "Backup already running, aborting."; exit 1; }

mkdir -p "$BACKUP_DIR"
SNAP_DIR="$BACKUP_DIR/.snapshot"
OUT_TMP=""
SERVER_STOPPED=false
START_TIME=$(date +%s)

# Runs on any exit: restarts the server if needed, cleans temp files, reports failures
cleanup() {
    local code=$?
    if [ "$SERVER_STOPPED" = true ]; then
        log "Starting server (cleanup)..."
        (cd "$SERVER_DIR" && docker compose up -d) || log "Failed to start server"
    fi
    rm -rf "$SNAP_DIR"
    if [ -n "$OUT_TMP" ]; then rm -rf "$OUT_TMP"; fi
    if [ "$code" -ne 0 ]; then
        tg_message "❌ <b>Minecraft backup FAILED</b>"$'\n'"Host: $(hostname)"$'\n'"Time: $(date '+%F %T')"$'\n'"Exit code: $code"$'\n'"Check: /root/backup.log"
    fi
}
trap cleanup EXIT

# ----- Advance warning, then wait -----
if [ "$INSTANT" = true ]; then
    log "Instant mode: skipping warning and wait."
    tg_message "🚨 <b>Emergency backup started</b>"$'\n'$'\n'"🖥 Host: $(hostname)"$'\n'"🛑 The server is being STOPPED right now."
    tg_message " /say Emergency backup started. The server is being STOPPED right now. Please leave the server and save your progress."
else
    BACKUP_AT=$(date -d "+${WARN_MINUTES} minutes" '+%H:%M')
    log "Sending advance warning. Backup starts at $BACKUP_AT."
    tg_message "⚠️ <b>Minecraft backup scheduled</b>"$'\n'$'\n'"🖥 Host: $(hostname)"$'\n'"🕒 Backup starts in ${WARN_MINUTES} minutes (at ${BACKUP_AT})"$'\n'"🛑 The server will be STOPPED during the backup"$'\n'"👥 Please leave the server and save your progress."
    tg_message "/say <b>Minecraft backup scheduled</b>"$'\n'$'\n'"🖥 Host: $(hostname)"$'\n'"🕒 Backup starts in ${WARN_MINUTES} minutes (at ${BACKUP_AT})"$'\n'"🛑 The server will be STOPPED during the backup"$'\n'"👥 Please leave the server and save your progress."

    log "Waiting ${WARN_MINUTES} minutes..."
    sleep $(( WARN_MINUTES * 60 ))
    tg_message "/say <b>Backup started after waiting 1 minute</b> - stopping the server now."
    sleep $(( 1 * 60 ))
    tg_message "🛑 <b>Backup started</b> - stopping the server now."
fi

# Reset the timer so total time excludes the waiting period
START_TIME=$(date +%s)

# Timestamp is taken after the wait, so it matches the real backup time
DATE=$(date +%F_%H-%M)
OUT_DIR="$BACKUP_DIR/minecraft_$DATE"
OUT_TMP="$BACKUP_DIR/.minecraft_${DATE}.tmp"
ARCHIVE_NAME="minecraft_$DATE.7z"

# Remove leftovers from any previous failed run
rm -rf "$SNAP_DIR" "$OUT_TMP"
mkdir -p "$SNAP_DIR" "$OUT_TMP"

# ----- Stop server and take a fast snapshot -----
cd "$SERVER_DIR"
log "Stopping server (waiting for world save)..."
STOP_TIME=$(date +%s)
docker compose stop -t 120
SERVER_STOPPED=true

log "Copying snapshot..."
cp -a "$SERVER_DIR" "$SNAP_DIR/"

# ----- Start server right away -----
log "Starting server..."
docker compose up -d
SERVER_STOPPED=false
DOWNTIME=$(( $(date +%s) - STOP_TIME ))
log "Server downtime: ${DOWNTIME}s"

# ----- Compress snapshot into multi-volume 7z -----
log "Creating multi-volume 7z archive..."
cd "$SNAP_DIR"
7z a -t7z -v"$VOLUME_SIZE" -mx="$COMPRESSION" -mmt=on -bso0 -bsp0 \
    "$OUT_TMP/$ARCHIVE_NAME" "$(basename "$SERVER_DIR")"

# Publish the finished backup
rm -rf "$OUT_DIR"
mv "$OUT_TMP" "$OUT_DIR"
OUT_TMP=""
rm -rf "$SNAP_DIR"

PARTS=$(ls -1 "$OUT_DIR" | wc -l)
SIZE=$(du -sh "$OUT_DIR" | cut -f1)
log "Created: $OUT_DIR ($SIZE, $PARTS parts)"

# ----- Rotate old backups -----
ls -1dt "$BACKUP_DIR"/minecraft_*/ 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -rv -- || true
COUNT=$(ls -1d "$BACKUP_DIR"/minecraft_*/ 2>/dev/null | wc -l)

# ----- Upload to Telegram -----
log "Uploading to Telegram..."
INDEX=0
for part in "$OUT_DIR"/*; do
    INDEX=$((INDEX + 1))
    log "Uploading part $INDEX/$PARTS..."
    tg_file "$part" "Backup $DATE - part $INDEX/$PARTS" || { log "Upload failed for part $INDEX"; exit 1; }
done

# ----- Final report -----
TOTAL=$(( $(date +%s) - START_TIME ))
DISK_FREE=$(df -h / | awk 'NR==2{print $4}')
DISK_USED=$(df -h / | awk 'NR==2{print $5}')
MODE="Scheduled"
[ "$INSTANT" = true ] && MODE="Emergency"

tg_message "✅ <b>Minecraft backup completed</b>"$'\n'$'\n'"🖥 Host: $(hostname)"$'\n'"🔖 Mode: $MODE"$'\n'"📅 Date: $(date '+%F %T')"$'\n'"📦 Archive: $ARCHIVE_NAME.001 ..."$'\n'"💾 Size: $SIZE"$'\n'"🧩 Telegram parts: $PARTS"$'\n'"⏱ Server downtime: ${DOWNTIME}s"$'\n'"⌛ Total time: ${TOTAL}s"$'\n'"🗂 Local backups kept: $COUNT/$KEEP"$'\n'"💽 Disk free: $DISK_FREE (used $DISK_USED)"

log "Done."
