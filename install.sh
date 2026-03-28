#!/bin/bash

set -e

echo "🚀 Starting Zero-Touch FreeRADIUS UI Deployment..."

# -------------------------------------------------
# Detect user
# -------------------------------------------------
if [ "$EUID" -eq 0 ]; then
    APP_USER=${SUDO_USER:-root}
else
    APP_USER=$(whoami)
fi

APP_HOME=$(eval echo "~$APP_USER")
APP_DIR=$(pwd)
VENV_DIR="$APP_DIR/venv"
SERVICE_FILE="/etc/systemd/system/freeradius-ui.service"
SUDOERS_FILE="/etc/sudoers.d/freeradius_ui"

echo "👤 Installing for user: $APP_USER"

# -------------------------------------------------
# Install dependencies
# -------------------------------------------------
echo "📦 Installing system packages..."

sudo apt-get update -y
sudo apt-get install -y \
    python3-venv \
    python3-pip \
    freeradius \
    freeradius-utils \
    net-tools

# -------------------------------------------------
# Ensure correct FreeRADIUS group
# -------------------------------------------------
echo "🔧 Checking FreeRADIUS group..."

if getent group freerad >/dev/null; then
    RADIUS_GROUP="freerad"
elif getent group freeradius >/dev/null; then
    RADIUS_GROUP="freeradius"
else
    sudo groupadd freerad
    RADIUS_GROUP="freerad"
fi

# Add our app user to the FreeRADIUS group so it inherits native group permissions
sudo usermod -aG $RADIUS_GROUP $APP_USER

# -------------------------------------------------
# Group Permissions Fix (Eliminates the need for sudo cp)
# -------------------------------------------------
echo "🔐 Setting secure group permissions..."

# Create CoA directory
sudo mkdir -p /etc/freeradius/3.0/coa

# Give the FreeRADIUS group ownership of the entire config tree
sudo chown -R root:$RADIUS_GROUP /etc/freeradius/3.0

# Allow the group to write to ALL directories (to create new files) EXCEPT certs
sudo find /etc/freeradius/3.0 -type d -not -path "*/certs*" -exec chmod 775 {} +

# Allow the group to write to ALL files (to edit existing files) EXCEPT certs
sudo find /etc/freeradius/3.0 -type f -not -path "*/certs*" -exec chmod 664 {} +

# Let the UI read the logs natively
sudo chown -R freerad:$RADIUS_GROUP /var/log/freeradius
sudo chmod -R 775 /var/log/freeradius
# -------------------------------------------------
# Python virtual environment
# -------------------------------------------------
echo "🐍 Creating Python environment..."

python3 -m venv $VENV_DIR
source $VENV_DIR/bin/activate

pip install --upgrade pip

if [ -f "requirements.txt" ]; then
    pip install -r requirements.txt
fi

# -------------------------------------------------
# Sudoers permissions (Minimized for Security!)
# -------------------------------------------------
echo "🛡️ Configuring minimal sudo permissions..."

# We ONLY grant what is strictly needed for Python's subprocess calls
cat <<EOF | sudo tee $SUDOERS_FILE >/dev/null
$APP_USER ALL=(ALL) NOPASSWD: /usr/sbin/freeradius -C
$APP_USER ALL=(ALL) NOPASSWD: /usr/bin/radclient
$APP_USER ALL=(ALL) NOPASSWD: /bin/systemctl restart freeradius
$APP_USER ALL=(ALL) NOPASSWD: /bin/systemctl is-active freeradius
EOF

sudo chmod 0440 $SUDOERS_FILE

# -------------------------------------------------
# Systemd service
# -------------------------------------------------
echo "⚙️ Creating systemd service..."

# Added UMask=0002 so any NEW files created by the app inherit rw-rw-r--
# allowing FreeRADIUS to read them.
sudo tee $SERVICE_FILE >/dev/null <<EOF
[Unit]
Description=FreeRADIUS Admin Web UI
After=network.target freeradius.service

[Service]
User=$APP_USER
Group=$RADIUS_GROUP
UMask=0002
WorkingDirectory=$APP_DIR
ExecStart=$VENV_DIR/bin/python app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# -------------------------------------------------
# Start services
# -------------------------------------------------
echo "🔄 Starting services..."

sudo systemctl daemon-reload
sudo systemctl enable freeradius --now
sudo systemctl enable freeradius-ui --now

# Restart the UI one last time to ensure it picks up the new group memberships
sudo systemctl restart freeradius-ui

# -------------------------------------------------
# Detect server IP
# -------------------------------------------------
SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
echo "🎉 Installation Completed!"
echo "-------------------------------------"
echo "📡 Server IP : $SERVER_IP"
echo "🌐 Web UI    : http://$SERVER_IP:8888"
echo "-------------------------------------"
echo "You can manage FreeRADIUS configuration securely from the web UI."