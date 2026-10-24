#!/bin/bash

# Ensure the script is run with root privileges
if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run this script with root privileges (sudo)."
  exit 1
fi

echo "[+] Starting project setup..."

# 1. Run setup_docker.sh if it exists
if [ -f "./setup_docker.sh" ]; then
    echo "[+] Running setup_docker.sh..."
    chmod +x /root/shammat/setup_docker.sh
    ./setup_docker.sh
else
    echo "[i] setup_docker.sh not found, skipping..."
fi

echo "----------------------------------------"
echo "[?] Please configure your Minecraft server:"
echo "----------------------------------------"

# 2. Interactive Questions
# Server Version (Mandatory Loop)
VERSION=""
while [ -z "$VERSION" ]; do
    read -p "Enter Minecraft Version (e.g., 1.21, 1.20.1,..., 26.3) [Required]: " VERSION
    if [ -z "$VERSION" ]; then
        echo "[-] Version cannot be empty. Please enter a version."
    fi
done

# Server Type / Edition (Including Forge & NeoForge)
echo "Select Minecraft Server Type:"
echo "1) VANILLA (Official standard)"
echo "2) FABRIC (Recommended for modern performance mods)"
echo "3) FORGE (Traditional modded servers)"
echo "4) NEOFORGE (Modern fork of Forge)"
echo "5) PAPER (High performance for plugins)"
read -p "Enter choice [1-5, default: 1]: " TYPE_CHOICE
case $TYPE_CHOICE in
    2) SERVER_TYPE="FABRIC" ;;
    3) SERVER_TYPE="FORGE" ;;
    4) SERVER_TYPE="NEOFORGE" ;;
    5) SERVER_TYPE="PAPER" ;;
    *) SERVER_TYPE="VANILLA" ;;
esac

# Cracked or Premium (Online Mode)
read -p "Is the server cracked (No-Premium)? [y/N]: " IS_CRACKED
if [[ "$IS_CRACKED" =~ ^[Yy]$ ]]; then
    ONLINE_MODE="FALSE"
else
    ONLINE_MODE="TRUE"
fi

# Server Name (MOTD)
read -p "Enter Server Name/MOTD (default: My Minecraft Server): " SERVER_NAME
SERVER_NAME=${SERVER_NAME:-My Minecraft Server}

# World Name / Seed
read -p "Enter World Name (default: world): " WORLD_NAME
WORLD_NAME=${WORLD_NAME:-world}

read -p "Enter World Seed (Leave empty for random seed): " WORLD_SEED

# RAM Allocation
while [ -z "$MEMORY" ]; do
    read -p "Enter RAM allocation for the game (e.g., 2G, 4G, 8G) [Required]: " MEMORY
    if [ -z "$MEMORY" ]; then
        echo "[-] Memory allocation cannot be empty. Please enter a value."
    fi
done

# Max Players limit
read -p "Enter Max Players limit (default: 20): " MAX_PLAYERS
MAX_PLAYERS=${MAX_PLAYERS:-20}

# Fixed Port
PORT="8080"
echo "[i] Server port is locked to: $PORT"

# 3. Ensure UFW Firewall allows the port (Linux)
if command -v ufw &> /dev/null; then
    echo "[+] Opening port $PORT in UFW firewall..."
    ufw allow $PORT/tcp
    ufw reload
fi

# 4. Create the root directory for Minecraft
MC_DIR="/root/minecraft"
mkdir -p "$MC_DIR/data"

# 5. Generate docker-compose.yml inside /root/minecraft
echo "[+] Generating docker-compose.yml..."

cat <<EOF > "$MC_DIR/docker-compose.yml"
version: "3.8"

services:
  minecraft:
    image: itzg/minecraft-server:latest
    container_name: minecraft-server
    restart: unless-stopped
    ports:
      - "$PORT:$PORT"
    environment:
      EULA: "TRUE"
      TYPE: "$SERVER_TYPE"
      VERSION: "$VERSION"
      MEMORY: "$MEMORY"
      SERVER_PORT: "$PORT"
      ONLINE_MODE: "$ONLINE_MODE"
      MOTD: "$SERVER_NAME"
      LEVEL_NAME: "$WORLD_NAME"
      SEED: "$WORLD_SEED"
      MAX_PLAYERS: "$MAX_PLAYERS"
    volumes:
      - ./data:/data
EOF

echo "[✓] Setup configuration generated successfully at $MC_DIR!"
echo "[+] Starting the Minecraft server container..."

cd "$MC_DIR"
docker compose up -d

echo "[✓] Minecraft server is now starting! You can check logs using: docker logs -f minecraft-server"
