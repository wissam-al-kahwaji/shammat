#!/bin/bash

# Ensure script is run with root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root (use sudo)." >&2
  exit 1
fi

TARGET_DIR="/root/shammat"
REPO_URL="https://github.com/wissam-al-kahwaji/shammat.git"

echo "Installing shammat to $TARGET_DIR..."

# Create target directory and get files
mkdir -p "$TARGET_DIR"

set -e   # stop on any error, so failures aren't reported as success

if [ -f "manager.sh" ]; then
    mkdir -p "$TARGET_DIR"
    cp -a ./. "$TARGET_DIR/"      # includes hidden files
else
    rm -rf "$TARGET_DIR"          # removes the directory itself, hidden files included
    git clone "$REPO_URL" "$TARGET_DIR"
fi

# Make manager.sh executable
chmod +x "$TARGET_DIR/manager.sh"

# Create the global 'shammat' command
cat << 'EOF' > /usr/local/bin/shammat
#!/bin/bash
cd /root/shammat
exec ./manager.sh "$@"
EOF

chmod +x /usr/local/bin/shammat

echo "Installation completed successfully!"
echo "Type 'shammat' from anywhere to run the tool."
