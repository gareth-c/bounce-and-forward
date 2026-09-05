#!/usr/bin/env bash
# One-time provisioning script for a fresh Ubuntu EC2 instance.
# Run as: sudo REPO_URL=https://github.com/you/bounce-and-forward.git bash deploy/setup-ec2.sh
#
# What it does:
#   - installs Node.js 22.x (via NodeSource)
#   - creates a dedicated, non-root service user
#   - clones the repo to /opt/bounce-and-forward
#   - installs production dependencies
#   - installs the systemd unit (grants CAP_NET_BIND_SERVICE so the service
#     user can bind port 25 without running as root)
#
# It does NOT start the service — you still need to create and fill in .env
# (copy from .env.example, set ALLOWED_RECIPIENTS / WEB_USERNAME /
# WEB_PASSWORD_HASH / SESSION_SECRET) before running:
#   sudo systemctl enable --now bounce-and-forward

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this with sudo/root (it installs packages and a systemd unit)." >&2
  exit 1
fi

REPO_URL="${REPO_URL:-}"
if [ -z "$REPO_URL" ]; then
  echo "Set REPO_URL to your git repo, e.g.:" >&2
  echo "  sudo REPO_URL=https://github.com/you/bounce-and-forward.git bash deploy/setup-ec2.sh" >&2
  exit 1
fi

INSTALL_DIR="/opt/bounce-and-forward"
SERVICE_USER="bounceforward"

echo "==> Installing Node.js 22.x"
if ! command -v node >/dev/null 2>&1 || [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 22 ]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
fi
node --version

echo "==> Creating service user '$SERVICE_USER'"
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
  useradd --system --create-home --shell /usr/sbin/nologin "$SERVICE_USER"
fi

echo "==> Fetching repo into $INSTALL_DIR"
if [ -d "$INSTALL_DIR/.git" ]; then
  git -C "$INSTALL_DIR" pull --ff-only
else
  git clone "$REPO_URL" "$INSTALL_DIR"
fi
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"

echo "==> Installing production dependencies"
sudo -u "$SERVICE_USER" bash -c "cd '$INSTALL_DIR' && npm ci --omit=dev"

if [ ! -f "$INSTALL_DIR/.env" ]; then
  cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"
  chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/.env"
  chmod 600 "$INSTALL_DIR/.env"
  echo "==> Created $INSTALL_DIR/.env from .env.example — edit it before starting the service."
fi

echo "==> Installing systemd unit"
cp "$INSTALL_DIR/deploy/bounce-and-forward.service" /etc/systemd/system/bounce-and-forward.service
systemctl daemon-reload

cat <<EOF

Setup complete. Before starting the service:

  1. Edit $INSTALL_DIR/.env — set SMTP_PORT=25, ALLOWED_RECIPIENTS,
     WEB_USERNAME, SESSION_SECRET (openssl rand -hex 32), and
     WEB_PASSWORD_HASH (generate with:
       sudo -u $SERVICE_USER bash -c "cd $INSTALL_DIR && npm run hash-password -- 'your-password'"
     )
  2. Open port 25 (and your chosen WEB_PORT, restricted to your own IP) in
     the EC2 security group.
  3. Start it:
       systemctl enable --now bounce-and-forward
       systemctl status bounce-and-forward
       journalctl -u bounce-and-forward -f

To redeploy after pushing new commits, run deploy/deploy.sh (see README).
EOF
