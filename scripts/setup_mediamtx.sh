#!/bin/bash
# ==============================================================================
# Automated MediaMTX WebRTC/WHEP & RTMP Setup Script for Linux VPS
# ==============================================================================
#
# This script installs MediaMTX, opens the firewall ports, configures WebRTC,
# and sets up a systemd service to keep the server running continuously in the background.

set -e

# Configuration
MEDIAMTX_VERSION="v1.9.0"
INSTALL_DIR="/opt/mediamtx"
SYSTEMD_SERVICE="/etc/systemd/system/mediamtx.service"

echo "=== 1. Downloading MediaMTX ${MEDIAMTX_VERSION} ==="
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# Detect Architecture
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    TARBALL="mediamtx_${MEDIAMTX_VERSION}_linux_amd64.tar.gz"
elif [ "$ARCH" = "aarch64" ]; then
    TARBALL="mediamtx_${MEDIAMTX_VERSION}_linux_arm64v8.tar.gz"
else
    echo "Unsupported CPU architecture: $ARCH"
    exit 1
fi

rm -f "$TARBALL"
if [ ! -f "$TARBALL" ]; then
    echo "Downloading tarball: $TARBALL..."
    wget -O "$TARBALL" "https://github.com/aler9/mediamtx/releases/download/${MEDIAMTX_VERSION}/${TARBALL}"
fi

echo "Extracting archive..."
tar -xzf "$TARBALL"
rm -f "$TARBALL"

echo "=== 2. Creating Custom mediamtx.yml Configuration ==="
# Write configuration with WebRTC (WHEP) and RTMP enabled
cat << 'EOF' > mediamtx.yml
# MediaMTX Configuration for Sand-Mining Detection Drone Stream

# Port configurations
rtmpAddress: :1935
rtspAddress: :8554
hlsAddress: :8888
webrtcAddress: :8889

# Required for WebRTC/WHEP browser cross-origin requests
webrtcAllowOrigin: "*"

# Enable HTTPS/SSL for WebRTC signaling
webrtcEncryption: true # Supports both HTTP and HTTPS clients
encryption: "no" # encryption on RTSP stream (keeps raw streams fast)

# SSL Certificate paths for WebRTC (WHEP/WHEPS) secure connection
webrtcServerKey: "/etc/letsencrypt/live/sandmining.nielitbhubaneswar.in/privkey.pem"
webrtcServerCert: "/etc/letsencrypt/live/sandmining.nielitbhubaneswar.in/fullchain.pem"

# Automatically enable ICE candidate gathering over STUN
webrtcICEServers:
  - stun:stun.l.google.com:19302
  - stun:stun1.l.google.com:19302

# Paths configuration
paths:
  # General path for drone stream
  # Access RTMP Ingest at: rtmp://<VPS_IP>:1935/live/<drone_id>
  # Access WHEP egress at: https://<VPS_IP>:8889/<drone_id>/whep
  all:
EOF

echo "=== 3. Registering Systemd Daemon Service ==="
# Write service file to keep MediaMTX running in the background
sudo bash -c "cat << 'EOF' > $SYSTEMD_SERVICE
[Unit]
Description=MediaMTX Realtime Media Server
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/mediamtx
Restart=always
RestartSec=5
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=mediamtx

[Install]
WantedBy=multi-user.target
EOF"

echo "Reloading systemd, enabling and starting MediaMTX..."
sudo systemctl daemon-reload
sudo systemctl enable mediamtx
sudo systemctl restart mediamtx

echo "=== 4. Updating Firewall Ports ==="
# Open necessary firewall ports using UFW if active
if command -v ufw >/dev/null 2>&1; then
    echo "Configuring UFW rules..."
    sudo ufw allow 1935/tcp  # RTMP Ingest
    sudo ufw allow 8889/tcp  # WebRTC (WHEP Signalling)
    sudo ufw allow 8554/tcp  # RTSP (optional streaming)
    sudo ufw allow 8000/tcp  # FastAPI dashboard (dashboard)
    sudo ufw allow 8888/tcp  # HLS (optional playback)
    sudo ufw allow 8000:9000/udp # WebRTC ICE candidate UDP range
    sudo ufw reload
fi

echo "=============================================================================="
echo "✓ Setup Complete! MediaMTX is now running in the background."
echo "  - Control logs:  sudo journalctl -u mediamtx -f"
echo "  - RTMP Ingest:   rtmp://<VPS_IP>:1935/live/drone"
echo "  - WebRTC WHEP:   http://<VPS_IP>:8889/drone/whep"
echo "=============================================================================="
