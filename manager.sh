#!/bin/bash

# Ensure the script is run with root privileges
if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run this script with root privileges (sudo)."
  exit 1
fi

# Force working directory to where manager.sh is located (/root/shammat)
cd "$(dirname "$0")"
BOT_DIR="$PWD"

# CHMOD all scripts to be executable safely using absolute paths
chmod +x "$BOT_DIR/setup_server.sh" 2>/dev/null
chmod +x "$BOT_DIR/backup.sh" 2>/dev/null
chmod +x "$BOT_DIR/setup_bot.sh" 2>/dev/null
chmod +x "$BOT_DIR/restart_bot.sh" 2>/dev/null
chmod +x "$BOT_DIR/remove_bot.sh" 2>/dev/null
chmod +x "$BOT_DIR/command.sh" 2>/dev/null

MC_DIR="/root/minecraft"
BACKUP_DIR="/root/backups"
CONTAINER_NAME="minecraft-server"
BOT_SERVICE="shammat.service"
BACKUP_PLAYERS_FILE="$BOT_DIR/backup_players.json"

# Pause utility to return home safely
pause() {
    echo ""
    read -p "Press [Enter] to return to the Home menu..."
}

# Dynamic System Status Checks
check_mc_installed() {
    [ -f "$MC_DIR/docker-compose.yml" ]
}

check_mc_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"
}

check_bot_installed() {
    systemctl list-unit-files "${BOT_SERVICE}" 2>/dev/null | grep -q "${BOT_SERVICE}"
}

check_bot_running() {
    systemctl is-active --quiet "${BOT_SERVICE}" 2>/dev/null
}

# Manage In-Game Backup Players (backup_players.json)
manage_backup_players() {
    # Ensure file exists
    if [ ! -f "$BACKUP_PLAYERS_FILE" ]; then
        mkdir -p "$BOT_DIR"
        echo '{"backup_players": []}' > "$BACKUP_PLAYERS_FILE"
    fi

    while true; do
        clear
        echo "=================================================="
        echo "           In-Game Backup Admins Manager          "
        echo "=================================================="
        echo "Current authorized players to run !backup:"
        echo "--------------------------------------------------"
        
        # Read and display current players using python
        python3 -c '
import json
try:
    with open("'$BACKUP_PLAYERS_FILE'", "r") as f:
        data = json.load(f)
        players = data.get("backup_players", [])
        if not players:
            print(" (No players authorized yet - everyone can backup or list is empty)")
        else:
            for idx, p in enumerate(players, 1):
                print(f" {idx}) {p}")
except Exception as e:
    print(f"[-] Error reading file: {e}")
'
        echo "--------------------------------------------------"
        echo "1) Add a Player"
        echo "2) Remove a Player"
        echo "3) Back to Main Menu"
        echo "--------------------------------------------------"
        read -p "Select choice [1-3]: " BP_CHOICE

        case $BP_CHOICE in
            1)
                read -p "Enter Minecraft username to ADD: " NEW_PLAYER
                if [ -n "$NEW_PLAYER" ]; then
                    python3 -c '
import json
file_path = "'$BACKUP_PLAYERS_FILE'"
new_p = "'$NEW_PLAYER'"
try:
    with open(file_path, "r") as f:
        data = json.load(f)
    if "backup_players" not in data:
        data["backup_players"] = []
    if new_p not in data["backup_players"]:
        data["backup_players"].append(new_p)
        with open(file_path, "w") as f:
            json.dump(data, f, indent=2)
        print(f"[✓] Player '\''{new_p}'\'' added successfully.")
    else:
        print(f"[!] Player '\''{new_p}'\'' is already in the list.")
except Exception as e:
    print(f"[-] Error: {e}")
'
                fi
                pause
                ;;
            2)
                read -p "Enter Minecraft username to REMOVE: " REM_PLAYER
                if [ -n "$REM_PLAYER" ]; then
                    python3 -c '
import json
file_path = "'$BACKUP_PLAYERS_FILE'"
rem_p = "'$REM_PLAYER'"
try:
    with open(file_path, "r") as f:
        data = json.load(f)
    players = data.get("backup_players", [])
    if rem_p in players:
        players.remove(rem_p)
        data["backup_players"] = players
        with open(file_path, "w") as f:
            json.dump(data, f, indent=2)
        print(f"[✓] Player '\''{rem_p}'\'' removed successfully.")
    else:
        print(f"[!] Player '\''{rem_p}'\'' not found in the list.")
except Exception as e:
    print(f"[-] Error: {e}")
'
                fi
                pause
                ;;
            3|*) break ;;
        esac
    done
}

# 1. Dynamic Server Control
server_status() {
    while true; do
        clear
        echo "=================================================="
        echo "               Server Status & Control            "
        echo "=================================================="

        if ! check_mc_installed; then
            echo "[Status] Minecraft Server is NOT INSTALLED."
            echo "--------------------------------------------------"
            echo "1) Install Minecraft Server Now (setup_server.sh)"
            echo "2) Back to Main Menu"
            echo "--------------------------------------------------"
            read -p "Select choice [1-2]: " CHOICE
            case $CHOICE in
                1) 
                    if [ -f "$BOT_DIR/setup_server.sh" ]; then
                        "$BOT_DIR/setup_server.sh"
                    else
                        echo "[-] setup_server.sh not found!"
                    fi
                    pause 
                    ;;
                2|*) break ;;
            esac
            continue
        fi

        if check_mc_running; then
            echo "[Status] Minecraft Server is RUNNING."
            echo "--------------------------------------------------"
            echo "1) View Live Logs (Press Ctrl+C inside logs to return)"
            echo "2) Stop Server (docker compose down)"
            echo "3) Restart Server"
            echo "4) Back to Main Menu"
            echo "--------------------------------------------------"
            read -p "Select choice [1-4]: " CHOICE
            case $CHOICE in
                1) 
                    docker logs -f "$CONTAINER_NAME"
                    pause
                    ;;
                2) cd "$MC_DIR" && docker compose down && echo "[✓] Server stopped." ; pause ;;
                3) cd "$MC_DIR" && docker compose restart && echo "[✓] Server restarted." ; pause ;;
                4|*) break ;;
            esac
        else
            echo "[Status] Minecraft Server is STOPPED."
            echo "--------------------------------------------------"
            echo "1) Start Server (docker compose up -d)"
            echo "2) View Last Logs"
            echo "3) Back to Main Menu"
            echo "--------------------------------------------------"
            read -p "Select choice [1-3]: " CHOICE
            case $CHOICE in
                1) cd "$MC_DIR" && docker compose up -d && echo "[✓] Server started." ; pause ;;
                2) docker logs --tail 100 "$CONTAINER_NAME" ; pause ;;
                3|*) break ;;
            esac
        fi
    done
}

# 2. Backup Manager & Restore
backup_manager() {
    while true; do
        clear
        echo "=================================================="
        echo "               Backup Manager & Restore           "
        echo "=================================================="
        echo "1) Take Manual Backup Now (backup.sh)"
        echo "2) Browse & Restore Previous Backup from /root/backups"
        echo "3) Back to Main Menu"
        echo "--------------------------------------------------"
        read -p "Select choice [1-3]: " BKP_CHOICE

        case $BKP_CHOICE in
            1)
                if [ -f "$BOT_DIR/backup.sh" ]; then
                    echo "[+] Running backup script..."
                    "$BOT_DIR/backup.sh" --now
                else
                    echo "[-] backup.sh not found!"
                fi
                pause
                ;;
            2)
                if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A $BACKUP_DIR 2>/dev/null)" ]; then
                    echo "[-] No backup directories found in $BACKUP_DIR."
                    pause
                    continue
                fi

                echo "Available Backups:"
                echo "--------------------------------------------------"
                BACKUPS=($(ls -d $BACKUP_DIR/minecraft_* 2>/dev/null | xargs -n 1 basename))
                
                if [ ${#BACKUPS[@]} -eq 0 ]; then
                    echo "[-] No valid backup folders found."
                    pause
                    continue
                fi

                for i in "${!BACKUPS[@]}"; do
                    echo "$((i+1))) ${BACKUPS[$i]}"
                done
                echo "--------------------------------------------------"
                
                read -p "Select backup number to restore (0 to cancel): " RESTORE_INDEX
                if [[ "$RESTORE_INDEX" -eq 0 || -z "$RESTORE_INDEX" ]]; then pause; continue; fi

                SELECTED_BACKUP="${BACKUPS[$((RESTORE_INDEX-1))]}"
                if [ -z "$SELECTED_BACKUP" ]; then echo "[-] Invalid selection." ; pause ; continue ; fi

                echo "[!] WARNING: Restoring will overwrite current data in $MC_DIR!"
                read -p "Proceed with restoring '$SELECTED_BACKUP'? [y/N]: " CONFIRM
                
                if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                    echo "[+] Stopping Minecraft server..."
                    [ -d "$MC_DIR" ] && (cd "$MC_DIR" && docker compose down 2>/dev/null)

                    if ! command -v 7z &> /dev/null && ! command -v 7za &> /dev/null; then
                        apt-get update && apt-get install -y p7zip-full
                    fi

                    FIRST_PART=$(ls $BACKUP_DIR/$SELECTED_BACKUP/*.7z.001 2>/dev/null | head -n 1)
                    if [ -z "$FIRST_PART" ]; then echo "[-] Archive split file (.7z.001) not found!" ; pause ; continue ; fi

                    echo "[+] Clearing current server directory and extracting backup..."
                    rm -rf "$MC_DIR"
                    mkdir -p "$MC_DIR"
                    7z x "$FIRST_PART" -o/root/ -y

                    echo "[+] Starting restored Minecraft server..."
                    if [ -f "$MC_DIR/docker-compose.yml" ]; then
                        cd "$MC_DIR" && docker compose up -d
                        echo "[✓] Restore finished successfully and server is running!"
                    else
                        echo "[!] Warning: docker-compose.yml not found in the extracted backup folder."
                    fi
                fi
                pause
                ;;
            3|*) break ;;
        esac
    done
}

# 3. Game Console Interface
game_console() {
    if ! check_mc_running; then
        echo "[-] Error: Minecraft server is not running! Start it first."
        pause
        return
    fi

    if [ -f "$BOT_DIR/command.sh" ]; then
        "$BOT_DIR/command.sh"
    else
        echo "[-] command.sh not found!"
    fi
    pause
}

# 4. Smart Telegram Bot Control
bot_manager() {
    while true; do
        clear
        echo "=================================================="
        echo "               Shammat Bot Management             "
        echo "=================================================="

        if check_bot_installed; then
            if check_bot_running; then
                echo "[Status] Bot Service: ACTIVE & RUNNING"
            else
                echo "[Status] Bot Service: INSTALLED (STOPPED)"
            fi
            echo "--------------------------------------------------"
            echo "1) Restart Bot Service"
            echo "2) Reconfigure / Update Telegram Credentials"
            echo "3) Remove Bot Service (uninstall)"
            echo "4) Back to Main Menu"
            echo "--------------------------------------------------"
            read -p "Select choice [1-4]: " BOT_CHOICE
            case $BOT_CHOICE in
                1) [ -f "$BOT_DIR/restart_bot.sh" ] && "$BOT_DIR/restart_bot.sh" ; pause ;;
                2) [ -f "$BOT_DIR/setup_bot.sh" ] && "$BOT_DIR/setup_bot.sh" ; pause ;;
                3) [ -f "$BOT_DIR/remove_bot.sh" ] && "$BOT_DIR/remove_bot.sh" ; pause ;;
                4|*) break ;;
            esac
        else
            echo "[Status] Bot Service: NOT INSTALLED"
            echo "--------------------------------------------------"
            echo "1) Install & Configure Telegram Bot Now (setup_bot.sh)"
            echo "2) Back to Main Menu"
            echo "--------------------------------------------------"
            read -p "Select choice [1-2]: " BOT_CHOICE
            case $BOT_CHOICE in
                1) [ -f "$BOT_DIR/setup_bot.sh" ] && "$BOT_DIR/setup_bot.sh" || echo "[-] setup_bot.sh not found!" ; pause ;;
                2|*) break ;;
            esac
        fi
    done
}

# 5. Smart Installation & Setup Menu
setup_and_maintenance() {
    while true; do
        clear
        echo "=================================================="
        echo "            Installation & Maintenance            "
        echo "=================================================="
        
        echo "Current System Status:"
        if check_mc_installed; then
            echo " - Minecraft Server: INSTALLED"
        else
            echo " - Minecraft Server: NOT INSTALLED"
        fi

        if check_bot_installed; then
            echo " - Shammat Bot: INSTALLED"
        else
            echo " - Shammat Bot: NOT INSTALLED"
        fi
        echo "--------------------------------------------------"

        if ! check_mc_installed; then
            echo "1) Install Minecraft Server (setup_server.sh)"
        else
            echo "1) Re-configure / Overwrite Minecraft Server (setup_server.sh)"
        fi

        if ! check_bot_installed; then
            echo "2) Install Shammat Bot Service (setup_bot.sh)"
        else
            echo "2) Remove Shammat Bot Service (remove_bot.sh)"
        fi
        echo "3) Back to Main Menu"
        echo "--------------------------------------------------"

        read -p "Select choice [1-3]: " M_CHOICE
        case $M_CHOICE in
            1) 
                if [ -f "$BOT_DIR/setup_server.sh" ]; then
                    "$BOT_DIR/setup_server.sh"
                else
                    echo "[-] setup_server.sh not found!"
                fi
                pause
                ;;
            2)
                if ! check_bot_installed; then
                    [ -f "$BOT_DIR/setup_bot.sh" ] && "$BOT_DIR/setup_bot.sh" || echo "[-] setup_bot.sh not found!"
                else
                    [ -f "$BOT_DIR/remove_bot.sh" ] && "$BOT_DIR/remove_bot.sh" || echo "[-] remove_bot.sh not found!"
                fi
                pause
                ;;
            3|*) break ;;
        esac
    done
}

# Main Interactive Loop (Home Menu)
while true; do
    clear
    echo "=================================================="
    echo "       SHAMMAT SYSTEM CONTROL CENTER (MANAGER)    "
    echo "=================================================="
    echo " Developer : Wissam Al-Kahwaji                    "
    echo " GitHub    : https://github.com/wissam-al-kahwaji "
    echo "=================================================="
    
    MC_STATUS="STOPPED"
    check_mc_running && MC_STATUS="RUNNING"
    ! check_mc_installed && MC_STATUS="NOT INSTALLED"

    BOT_STATUS="NOT INSTALLED"
    check_bot_installed && BOT_STATUS="INSTALLED"
    check_bot_running && BOT_STATUS="RUNNING"

    echo " [Server: $MC_STATUS]  |  [Bot: $BOT_STATUS]"
    echo "=================================================="
    echo " 1) Server Status & Power Control"
    echo " 2) Interactive In-Game Console (rcon)"
    echo " 3) Backup Manager & Server Restore"
    echo " 4) Shammat Telegram Bot Manager"
    echo " 5) Setup & Installation Center"
    echo " 6) Manage In-Game Backup Admins (!backup)"
    echo " type 'exit' to Close Control Panel"
    echo "=================================================="
    read -p "Enter choice or command: " MAIN_CHOICE

    if [[ "$MAIN_CHOICE" == "exit" ]]; then
        echo "[+] Exiting Control Panel. Goodbye!"
        exit 0
    fi

    case $MAIN_CHOICE in
        1) server_status ;;
        2) game_console ;;
        3) backup_manager ;;
        4) bot_manager ;;
        5) setup_and_maintenance ;;
        6) manage_backup_players ;;
        *) 
           echo "[-] Invalid option! Type 'exit' to quit the panel."
           sleep 1
           ;;
    esac
done
