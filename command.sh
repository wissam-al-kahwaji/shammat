#!/bin/bash

# Define the container name
CONTAINER_NAME="minecraft-server"

# Check if the container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "[-] Error: Container '${CONTAINER_NAME}' is not running!"
    exit 1
fi

echo "=================================================="
echo "    Minecraft Interactive Command Interface       "
echo "=================================================="
echo "Type your Minecraft command and press Enter."
echo "Type 'exit' or 'quit' to close this interface."
echo "--------------------------------------------------"

# Interactive loop
while true; do
    # Read user command with a custom prompt
    read -p "MC-Server > " MC_CMD

    # Check if user wants to exit
    if [[ "$MC_CMD" == "exit" || "$MC_CMD" == "quit" ]]; then
        echo "[+] Exiting command interface."
        break
    fi

    # Skip empty input
    if [ -z "$MC_CMD" ]; then
        continue
    fi

    # Send command via rcon-cli inside the container
    echo "[+] Executing: $MC_CMD"
    docker exec "$CONTAINER_NAME" rcon-cli "$MC_CMD"
    echo "--------------------------------------------------"
done