#!/usr/bin/env bash
# One-time provisioning script for a fresh Ubuntu server (EC2 or otherwise).
# Prompts interactively for anything not already given via env var — run it
# bare and it'll ask; pre-set the env vars (e.g. in CI) and it runs
# unattended with no prompts at all. Either way it needs root:
#
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/gareth-c/bounce-and-forward/main/install.sh)"
#
# (That "bash -c "$(curl ...)"" form — not "curl | bash" — matters: it's
# what lets the interactive prompts below actually reach your terminal
# instead of trying to read the piped script bytes as input.)
#
# What it does:
#   - installs Node.js 22.x (via NodeSource)
#   - creates a dedicated, non-root service user
#   - clones the repo to /opt/bounce-and-forward
#   - installs production dependencies
#   - if given a domain: installs Caddy and configures it as a
#     TLS-terminating reverse proxy in front of the web UI, with automatic
#     Let's Encrypt issuance/renewal (see README's "TLS for the web UI"
#     section). Requires that domain's DNS to already point at this
#     instance's public IP before Caddy can obtain a certificate for it.
#     Leave it blank to skip this and stay on plain HTTP.
#   - on first run only (skipped if .env already exists, so reruns never
#     clobber it): creates .env from the answers below, with a freshly
#     generated SESSION_SECRET and a bcrypt hash of the password (the
#     plaintext password itself is never written to disk or passed as a
#     command-line argument anywhere — only piped over stdin into the
#     hashing step)
#   - installs the systemd unit (grants CAP_NET_BIND_SERVICE so the service
#     user can bind port 25 without running as root) and starts it
#
# Env vars (all optional — you're prompted for anything left unset, when
# running interactively): REPO_URL, CADDY_DOMAIN, SMTP_PORT,
# ALLOWED_RECIPIENTS, WEB_USERNAME, WEB_PASSWORD (plaintext — hashed before
# it touches disk) or WEB_PASSWORD_HASH (pre-hashed, used as-is),
# NONINTERACTIVE=1 to force non-interactive mode even on a real terminal
# (fails fast on missing required values instead of prompting).

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this with sudo/root (it installs packages and a systemd unit)." >&2
  exit 1
fi

INSTALL_DIR="/opt/bounce-and-forward"
SERVICE_USER="bounceforward"

# needrestart's post-install process scan is known to spike memory hard
# enough to get OOM-killed on small instances (t4g.micro/nano-class) — seen
# in practice installing Caddy's dependencies. Skip it rather than let a
# package install fail non-deterministically partway through.
export NEEDRESTART_SUSPEND=1
export DEBIAN_FRONTEND=noninteractive

# Second line of defense for the same class of problem: add a swapfile on
# a low-memory instance with none yet, so a genuine memory spike degrades
# to "slow" instead of a process getting killed outright.
ensure_swap() {
  if ! command -v swapon >/dev/null 2>&1 || [ -n "$(swapon --show 2>/dev/null)" ]; then
    return 0
  fi
  local mem_kb
  mem_kb="$(awk '/MemTotal/ { print $2 }' /proc/meminfo 2>/dev/null || echo 0)"
  if [ "$mem_kb" -ge 1572864 ] || [ -f /swapfile ]; then
    return 0
  fi
  echo "==> Low-memory instance with no swap detected — adding a 1GB swapfile"
  fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab 2>/dev/null || echo '/swapfile none swap sw 0 0' >> /etc/fstab
}

# Only prompt when there's an actual terminal to prompt on — never hang a
# CI run or a "curl | bash" (as opposed to "bash -c \"\$(curl ...)\"")
# invocation waiting on input that will never arrive. Reads come from
# /dev/tty rather than stdin so this also works even when stdin itself is
# occupied by a piped script.
INTERACTIVE=true
if [ -n "${NONINTERACTIVE:-}" ] || [ ! -e /dev/tty ] || ! { exec 3</dev/tty; } 2>/dev/null; then
  INTERACTIVE=false
fi

# ask PROMPT VARNAME [DEFAULT] — sets VARNAME from its existing env value if
# already set; otherwise prompts for it (showing DEFAULT, used if the reply
# is empty) when interactive; otherwise falls back to DEFAULT if given, or
# leaves VARNAME unset for the caller to handle.
ask() {
  local __prompt="$1" __var="$2" __default="${3-}" __reply
  if [ -n "${!__var:-}" ]; then
    return 0
  fi
  if [ "$INTERACTIVE" != true ]; then
    # Always assign, even when __default is "" — leaving __var completely
    # unset here would trip `set -u` wherever it's read later.
    printf -v "$__var" '%s' "$__default"
    return 0
  fi
  if [ -n "$__default" ]; then
    read -r -p "$__prompt [$__default]: " __reply <&3
    __reply="${__reply:-$__default}"
  else
    read -r -p "$__prompt: " __reply <&3
  fi
  printf -v "$__var" '%s' "$__reply"
  return 0
}

# Prompts for a password with hidden input and confirmation. Leaves it in
# WEB_PASSWORD (plaintext, in-memory only — never written to disk; hashed
# and unset once dependencies are installed, below).
ask_password() {
  if [ -n "${WEB_PASSWORD_HASH:-}" ] || [ -n "${WEB_PASSWORD:-}" ]; then
    return 0
  fi
  if [ "$INTERACTIVE" != true ]; then
    return 0
  fi
  local pw1 pw2
  while true; do
    read -rs -p "Web UI password for '$WEB_USERNAME': " pw1 <&3
    echo >&2
    read -rs -p "Confirm password: " pw2 <&3
    echo >&2
    if [ -z "$pw1" ]; then
      echo "Password cannot be empty." >&2
      continue
    fi
    if [ "$pw1" != "$pw2" ]; then
      echo "Passwords didn't match — try again." >&2
      continue
    fi
    WEB_PASSWORD="$pw1"
    break
  done
  return 0
}

echo "==> Bounce & Forward — installer"
echo

ask "Git repo URL to deploy" REPO_URL "https://github.com/gareth-c/bounce-and-forward.git"
REPO_URL="${REPO_URL:-}"
if [ -z "$REPO_URL" ]; then
  echo "REPO_URL is required. Either run this on a real terminal so it can ask, or set it:" >&2
  echo "  sudo REPO_URL=https://github.com/gareth-c/bounce-and-forward.git bash install.sh" >&2
  exit 1
fi

ask "Domain for TLS via Caddy, e.g. mail.yourdomain.com (leave blank to skip)" CADDY_DOMAIN
CADDY_DOMAIN="${CADDY_DOMAIN:-}"

# .env is only ever created once — a rerun (e.g. to add Caddy later) leaves
# an existing one untouched, so none of this needs asking again then.
NEED_ENV_SETUP=true
if [ -f "$INSTALL_DIR/.env" ]; then
  NEED_ENV_SETUP=false
fi

if [ "$NEED_ENV_SETUP" = true ]; then
  ask "SMTP port to listen on" SMTP_PORT "25"
  ask "Accepted recipients, comma-separated (blank is fine — manage later at /recipients)" ALLOWED_RECIPIENTS ""
  ask "Web UI username" WEB_USERNAME "admin"
  ask_password
  if [ -z "${WEB_PASSWORD_HASH:-}" ] && [ -z "${WEB_PASSWORD:-}" ]; then
    echo "WEB_PASSWORD or WEB_PASSWORD_HASH is required to create .env non-interactively." >&2
    echo "  sudo REPO_URL=... WEB_PASSWORD='...' bash install.sh" >&2
    exit 1
  fi
fi

if [ "$INTERACTIVE" = true ]; then
  echo
  echo "About to set up Bounce & Forward on this host:"
  echo "  Repo:   $REPO_URL"
  echo "  Domain: ${CADDY_DOMAIN:-(none — plain HTTP on WEB_PORT)}"
  if [ "$NEED_ENV_SETUP" = true ]; then
    echo "  SMTP port:  $SMTP_PORT"
    echo "  Recipients: ${ALLOWED_RECIPIENTS:-(none yet — add via /recipients)}"
    echo "  Web login:  $WEB_USERNAME / ********"
  else
    echo "  .env already exists — leaving it untouched."
  fi
  echo "This installs Node.js${CADDY_DOMAIN:+, Caddy,} and a systemd service, as root, and starts it."
  read -r -p "Press ENTER to continue, or Ctrl+C to abort... " _ <&3
  echo
fi

# Fresh cloud instances commonly still have cloud-init's own first-boot
# package setup running (holding the apt/dpkg lock) or left dpkg in an
# interrupted state once it finishes — both produce confusing apt-get
# failures if not handled before the first real apt-get call.
wait_for_apt() {
  if command -v fuser >/dev/null 2>&1; then
    local waited=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
      if [ "$waited" -ge 120 ]; then
        echo "Still waiting on the apt/dpkg lock after 2 minutes — giving up. Check what's holding it (e.g. 'ps aux | grep apt') and retry." >&2
        exit 1
      fi
      echo "    waiting for another apt/dpkg process to finish..."
      sleep 5
      waited=$((waited + 5))
    done
  fi
  # Repairs a dpkg left interrupted by cloud-init's own first-boot package
  # setup — the actual failure mode this is guarding against, independent
  # of whether the lock-wait above could even run.
  dpkg --configure -a
}

ensure_swap

echo "==> Installing Node.js 22.x"
wait_for_apt
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

if [ "$NEED_ENV_SETUP" = true ]; then
  echo "==> Writing $INSTALL_DIR/.env"

  if [ -z "${WEB_PASSWORD_HASH:-}" ]; then
    WEB_PASSWORD_HASH="$(
      printf '%s' "$WEB_PASSWORD" \
        | sudo -u "$SERVICE_USER" bash -c "cd '$INSTALL_DIR' && node bin/hash-password.js"
    )"
    unset WEB_PASSWORD
  fi
  SESSION_SECRET="$(node -e 'console.log(require("crypto").randomBytes(32).toString("hex"))')"

  cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"

  # Uses Node (already installed) rather than sed, so values containing
  # regex/sed-hostile characters — a bcrypt hash is full of $, ., / — can't
  # corrupt the file or one another.
  set_env() {
    node -e '
      const fs = require("fs");
      const [, file, key, value] = process.argv;
      const re = new RegExp("^" + key + "=.*$", "m");
      const line = key + "=" + value;
      const content = fs.readFileSync(file, "utf8");
      fs.writeFileSync(file, re.test(content) ? content.replace(re, () => line) : content + "\n" + line + "\n");
    ' "$INSTALL_DIR/.env" "$1" "$2"
  }

  set_env SMTP_PORT "$SMTP_PORT"
  set_env ALLOWED_RECIPIENTS "$ALLOWED_RECIPIENTS"
  set_env WEB_USERNAME "$WEB_USERNAME"
  set_env WEB_PASSWORD_HASH "$WEB_PASSWORD_HASH"
  set_env SESSION_SECRET "$SESSION_SECRET"
  if [ -n "$CADDY_DOMAIN" ]; then
    set_env WEB_SECURE_COOKIES "true"
    set_env WEB_TRUST_PROXY "true"
  fi

  chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/.env"
  chmod 600 "$INSTALL_DIR/.env"
fi

echo "==> Installing systemd unit"
cp "$INSTALL_DIR/deploy/bounce-and-forward.service" /etc/systemd/system/bounce-and-forward.service
systemctl daemon-reload

if [ -n "$CADDY_DOMAIN" ]; then
  echo "==> Installing Caddy (TLS reverse proxy for the web UI)"
  if ! command -v caddy >/dev/null 2>&1; then
    wait_for_apt
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update
    apt-get install -y caddy
  fi

  if [ ! -f /etc/caddy/Caddyfile ] || ! grep -q "$CADDY_DOMAIN" /etc/caddy/Caddyfile; then
    sed "s/mail.yourdomain.com/$CADDY_DOMAIN/" "$INSTALL_DIR/deploy/Caddyfile" > /etc/caddy/Caddyfile
    echo "==> Wrote /etc/caddy/Caddyfile for $CADDY_DOMAIN"
  fi
  systemctl enable caddy
  systemctl restart caddy
fi

echo "==> Starting bounce-and-forward"
systemctl enable --now bounce-and-forward
sleep 1
systemctl --no-pager status bounce-and-forward || true

cat <<EOF

Done. Remaining manual step: open the right ports in your firewall/security
group — this script doesn't touch that.
EOF

if [ -n "$CADDY_DOMAIN" ]; then
  cat <<EOF
  Open 25 (inbound mail) and 80+443 (Caddy/Let's Encrypt). WEB_PORT (8080)
  does not need to be open at all — the app listens on 127.0.0.1 only and
  is reached solely through Caddy at https://$CADDY_DOMAIN.
EOF
else
  cat <<EOF
  Open 25 (inbound mail), and WEB_PORT restricted to your own IP/VPN — not
  the world, since the web UI is plain HTTP. See the README's "TLS for the
  web UI" section to add that later.
EOF
fi

cat <<EOF

  journalctl -u bounce-and-forward -f   # watch logs
  sudo /opt/bounce-and-forward/deploy/deploy.sh main   # redeploy later
EOF
