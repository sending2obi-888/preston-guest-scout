#!/usr/bin/env bash
set -euo pipefail

# Installs Preston Guest Scout as a systemd user service in ChromeOS Linux (Googlebook)
# so the twice-daily (7:30 AM & 2:00 PM) Gemini Agent & Web App boot automatically at startup.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVICE_DIR="$HOME/.config/systemd/user"
mkdir -p "$SERVICE_DIR"

cat > "$SERVICE_DIR/preston-guest-scout.service" <<EOF
[Unit]
Description=Preston Guest Scout Backend & Web App (7:30 AM & 2:00 PM Gemini Agent)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$PROJECT_ROOT/backend
ExecStart=$(command -v node) $PROJECT_ROOT/backend/server.mjs
Restart=always
RestartSec=5
Environment=PORT=8080

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now preston-guest-scout.service
echo "Installed and started preston-guest-scout.service on port 8080."
