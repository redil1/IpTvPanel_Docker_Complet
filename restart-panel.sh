#!/bin/bash
# Helper script to restart the panel without breaking nginx connectivity

echo "Restarting IPTV Panel..."
docker-compose restart panel

echo "Waiting for panel to start..."
sleep 3

echo "Refreshing nginx connection..."
docker-compose restart nginx

echo "Done! Panel restarted successfully."
echo ""
echo "Access your panel at: https://panel.localtest.me"
