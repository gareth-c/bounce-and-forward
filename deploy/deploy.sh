#!/usr/bin/env bash
# Redeploy script — runs ON the server, invoked manually over SSH (see
# README's "Redeploying after code changes"). Pulls the latest commit,
# reinstalls production deps, restarts the service.

set -euo pipefail

INSTALL_DIR="/opt/bounce-and-forward"
SERVICE_USER="bounceforward"
SERVICE_NAME="bounce-and-forward"
BRANCH="${1:-main}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo (needs to restart a systemd service)." >&2
  exit 1
fi

echo "==> Pulling latest $BRANCH"
sudo -u "$SERVICE_USER" bash -c "cd '$INSTALL_DIR' && git fetch origin '$BRANCH' && git reset --hard 'origin/$BRANCH'"

echo "==> Installing production dependencies"
sudo -u "$SERVICE_USER" bash -c "cd '$INSTALL_DIR' && npm ci --omit=dev"

echo "==> Restarting $SERVICE_NAME"
systemctl restart "$SERVICE_NAME"
systemctl --no-pager status "$SERVICE_NAME"
