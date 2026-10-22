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
    ./setup_docker.sh
else
    echo "[i] setup_docker.sh not found, skipping..."
fi

echo "----------------------------------------"
echo "[?] Please configure your Minecraft server:"
echo "----------------------------------------"

# 2. Interactive Questions
# Server Version
read -p "Enter Minecraft Version (e.g., 1.21, 1.20.1): " VERSION
VERSION=${VERSION:-1.21}

# Server Type / Edition (Including Forge & NeoForge)
echo "Select Minecraft Server Type:"
echo "1) FABRIC (Recommended for modern performance mods)"
echo "2) FORGE (Traditional modded servers)"
echo "3) NEOFORGE (Modern fork of Forge)"
echo "4) PAPER (High performance for plugins)"
echo "5) VANILLA (Official standard)"
read -p "Enter choice [1-5, default: 1]: " TYPE_CHOICE
case $TYPE_CHOICE in
    2) SERVER_TYPE="FORGE" ;;
    3) SERVER_TYPE="NEOFORGE" ;;
    4) SERVER_TYPE="PAPER" ;;
    5) SERVER_TYPE="VANILLA" ;;
    *) SERVER_TYPE="FABRIC" ;;
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
read -p "Enter RAM allocation for the game (e.g., 2G, 4G, 8G): " MEMORY

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
    volumes:
      - ./data:/data
EOF

echo "[✓] Setup configuration generated successfully at $MC_DIR!"
echo "[+] Starting the Minecraft server container..."

cd "$MC_DIR"
docker compose up -d

echo "[✓] Minecraft server is now starting! You can check logs using: docker logs -f minecraft-server"