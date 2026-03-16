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

# -------------------------------------------------
# Permissions
# -------------------------------------------------
echo "🔐 Setting permissions..."

sudo mkdir -p /etc/freeradius/3.0/coa

sudo chown -R $APP_USER:$RADIUS_GROUP /etc/freeradius/3.0/coa
sudo chmod -R 775 /etc/freeradius/3.0/coa

sudo chown :$RADIUS_GROUP /etc/freeradius/3.0/users
sudo chmod 664 /etc/freeradius/3.0/users

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
# Sudoers permissions
# -------------------------------------------------
echo "🛡️ Configuring sudo permissions..."

cat <<EOF | sudo tee $SUDOERS_FILE >/dev/null
$APP_USER ALL=(ALL) NOPASSWD: /usr/sbin/tcpdump
$APP_USER ALL=(ALL) NOPASSWD: /bin/cp /etc/freeradius/3.0/users /tmp/users
$APP_USER ALL=(ALL) NOPASSWD: /bin/cp /tmp/users /etc/freeradius/3.0/users
$APP_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart freeradius
EOF

sudo chmod 0440 $SUDOERS_FILE

# -------------------------------------------------
# Systemd service
# -------------------------------------------------
echo "⚙️ Creating systemd service..."

sudo tee $SERVICE_FILE >/dev/null <<EOF
[Unit]
Description=FreeRADIUS Users Web UI
After=network.target freeradius.service

[Service]
User=$APP_USER
Group=$RADIUS_GROUP
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

# -------------------------------------------------
# Detect server IP
# -------------------------------------------------
SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
echo "🎉 Installation Completed!"
echo "-------------------------------------"
echo "📡 Server IP : $SERVER_IP"
echo "🌐 Web UI    : http://$SERVER_IP:5000"
echo "-------------------------------------"
echo "You can manage FreeRADIUS users from the web UI."