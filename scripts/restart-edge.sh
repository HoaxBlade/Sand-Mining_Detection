#!/bin/bash

# restart-edge: Interactive systemctl wrapper for drone RTMP link entry

echo "============================================================"
echo "BRAHMAPUTRA SURVEILLANCE EDGE COMPUTE SYSTEMCTL RESTART"
echo "============================================================"
read -p "Enter Drone RTMP/RTSP Link (or press Enter for default '0'): " user_input
echo "============================================================"

# If user input is empty, default to "0" (webcam fallback)
if [ -z "$user_input" ]; then
    user_input="0"
fi

# Write the link dynamically to systemd's environment file
# Requires sudo permissions to write to /etc/default/
echo "Writing environment configuration..."
echo "CAMERA_SOURCE=$user_input" | sudo tee /etc/default/sand-mining-edge > /dev/null

# Trigger systemctl service restart
echo "Restarting sand-mining-edge service..."
sudo systemctl restart sand-mining-edge

echo "Success! Service restarted with source: $user_input"
echo "============================================================"
