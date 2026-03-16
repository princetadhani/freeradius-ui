#!/bin/bash

# --- Auto-Config ---
APP_USER=$(whoami)
APP_DIR=$(pwd)
VENV_DIR="$APP_DIR/venv"
SUDOERS_FILE="/etc/sudoers.d/freeradius_ui"
SERVICE_FILE="/etc/systemd/system/freeradius-ui.service"

# Prevent interactive prompts
export DEBIAN_FRONTEND=noninteractive

echo "🚀 Starting Zero-Touch Deployment from GitHub..."

# 1. System Dependencies
sudo -E apt-get update -y
sudo -E apt-get install -y python3-venv python3-pip freeradius freeradius-utils

# 2. Permissions for FreeRADIUS
echo "🔐 Setting up system permissions..."
sudo mkdir -p /etc/freeradius/3.0/coa
sudo chown -R $APP_USER:freeradius /etc/freeradius/3.0/coa
sudo chmod -R 775 /etc/freeradius/3.0/coa
# Allow user to edit the 'users' file
sudo chown :freeradius /etc/freeradius/3.0/users
sudo chmod 664 /etc/freeradius/3.0/users

# 3. Python Environment
echo "🐍 Creating Virtual Environment..."
python3 -m venv venv
source venv/bin/activate
pip install --quiet --upgrade pip
if [ -f "requirements.txt" ]; then
    pip install --quiet -r requirements.txt
fi

# 4. Sudoers Policy
echo "🛡️ Applying NOPASSWD policies..."
cat <<EOF | sudo tee $SUDOERS_FILE > /dev/null
$APP_USER ALL=(ALL) NOPASSWD: /usr/sbin/tcpdump
$APP_USER ALL=(ALL) NOPASSWD: /bin/cp /etc/freeradius/3.0/users /tmp/users
$APP_USER ALL=(ALL) NOPASSWD: /bin/cp /tmp/users /etc/freeradius/3.0/users
$APP_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart freeradius
EOF
sudo chmod 0440 $SUDOERS_FILE

# 5. Systemd Service
echo "⚙️ Creating Systemd Service..."
cat <<EOF | sudo tee $SERVICE_FILE > /dev/null
[Unit]
Description=FreeRADIUS Users Web UI
After=network.target freeradius.service

[Service]
User=$APP_USER
Group=freeradius
WorkingDirectory=$APP_DIR
ExecStart=$VENV_DIR/bin/python app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# 6. Start
sudo systemctl daemon-reload
sudo systemctl enable freeradius-ui --now

echo "✅ Deployment finished successfully!"
