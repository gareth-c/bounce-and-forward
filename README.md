# Bounce & Forward

An SMTP daemon that listens for mail on port 25 for a configured list of
users/domains, **captures the full message**, then rejects it with a
permanent SMTP error — so the sender's mail server generates a real bounce
back to them, while you keep a copy. Captured mail is browsable in a
password-protected web UI.

## How the bounce works

The daemon accepts `MAIL FROM` / `RCPT TO` for configured addresses, reads
the entire message during `DATA`, and only *then* responds to the final `.`
with a 5xx error instead of `250 OK`. Two things fall out of that:

- The sender's own MTA is the one that generates the bounce message to their
  user — this server never originates outbound mail. That means it works
  fine even on hosts (like AWS EC2) that block or throttle *outbound* port
  25, since no outbound SMTP connection is ever made.
- Rejecting inline (rather than accepting and bouncing asynchronously later)
  avoids "backscatter" — you never send a bounce to a third party whose
  address was forged as the sender.

Addresses/domains not in the accepted list are rejected immediately at
`RCPT TO` with a normal 550, before any message is captured — nothing is
stored for them.

## Managing accepted addresses/domains

The list of addresses/domains to capture mail for lives in the database, not
just `.env`, and is managed at **/recipients** in the web UI — add a full
address (`alice@example.com`) or a bare domain (`example.com`, meaning
"every address at this domain") and remove them, with no restart or
redeploy needed; changes apply to the very next SMTP connection.

`ALLOWED_RECIPIENTS` in `.env` is only used to seed that list the first time
the server ever starts (so existing single-`.env` deployments keep working
unchanged) — after that it's ignored, and the web UI is the source of
truth.

## Local development

```bash
npm install
cp .env.example .env
npm run hash-password -- 'your-password' # paste result into WEB_PASSWORD_HASH in .env
```

Edit `.env`: set `ALLOWED_RECIPIENTS`, `WEB_USERNAME`, `SESSION_SECRET`
(`openssl rand -hex 32`). Leave `SMTP_PORT=2525` locally — port 25 needs
root/elevated capabilities (see below).

```bash
npm start
```

Then send a test message, e.g.:

```bash
python3 -c "
import smtplib
smtplib.SMTP('127.0.0.1', 2525).sendmail(
    'sender@example.com', ['alice@example.com'], 'Subject: test\n\nhi'
)
"
```

It should fail with a `550` from Python (that's the bounce working), and the
message should appear in the web UI at http://127.0.0.1:8080.

## Deploying to AWS EC2

Port 25 needs a real host with an unrestricted public IP and listening
socket — this won't run on PaaS platforms like Railway/Render/Heroku, which
don't expose raw port 25 to the internet.

### One-time setup

1. Launch an Ubuntu EC2 instance with an Elastic IP.
2. Security group: allow inbound TCP 25 from `0.0.0.0/0`; allow your chosen
   `WEB_PORT` only from your own IP/VPN (not the world) — the web UI has its
   own auth, but don't expose it needlessly; allow SSH (22) from your IP.
3. AWS blocks *outbound* port 25 by default on EC2 — irrelevant here since
   this daemon never sends outbound mail (see "How the bounce works" above),
   so you do **not** need to file the EC2 email-sending-limit removal
   request for this use case.
4. Optional but recommended: request a PTR (reverse DNS) record for your
   Elastic IP via an AWS Support case ("EC2 reverse DNS request"), and point
   an MX record for your domain(s) at the instance.
5. SSH in and run the provisioning script, pointing it at your git repo:

   ```bash
   sudo REPO_URL=https://github.com/you/bounce-and-forward.git \
     bash -c "$(curl -fsSL https://raw.githubusercontent.com/you/bounce-and-forward/main/deploy/setup-ec2.sh)"
   ```

   (Or `git clone` the repo first and run `deploy/setup-ec2.sh` locally on
   the box.) This installs Node.js, creates a `bounceforward` service user,
   clones the repo to `/opt/bounce-and-forward`, installs dependencies, and
   installs the systemd unit — but does **not** start the service yet.

6. Fill in `/opt/bounce-and-forward/.env` (set `SMTP_PORT=25`,
   `ALLOWED_RECIPIENTS`, `WEB_USERNAME`, `SESSION_SECRET`, and
   `WEB_PASSWORD_HASH` — the setup script prints the exact command to
   generate the hash).
7. Start it:

   ```bash
   sudo systemctl enable --now bounce-and-forward
   sudo systemctl status bounce-and-forward
   sudo journalctl -u bounce-and-forward -f
   ```

The systemd unit runs the service as the unprivileged `bounceforward` user
and grants only `CAP_NET_BIND_SERVICE` (via `AmbientCapabilities`) so it can
bind port 25 without running as root.

### Deploying from git (push-to-deploy)

`.github/workflows/deploy.yml` redeploys on every push to `main` by SSHing
into the instance and running `deploy/deploy.sh`, which does a `git fetch` +
hard reset to `origin/main`, reinstalls production dependencies, and
restarts the systemd service. `.env` is untracked so it's left alone.

To wire it up, add these repo secrets (Settings → Secrets and variables →
Actions):

- `EC2_HOST` — the instance's public IP or DNS name
- `EC2_USER` — the SSH login user (e.g. `ubuntu`)
- `EC2_SSH_KEY` — the private key for that user, PEM format

That SSH user needs passwordless `sudo` for `deploy/deploy.sh` specifically,
or just run the workflow as a user with general sudo (e.g. `ubuntu` on
standard AMIs already has NOPASSWD sudo).

You can also redeploy manually at any time:

```bash
ssh you@your-ec2-host 'sudo bash /opt/bounce-and-forward/deploy/deploy.sh main'
```

## Configuration reference

See [.env.example](.env.example) — every variable is documented inline.

## Security notes

- The web UI is single-user (one username/password from `.env`, bcrypt
  hashed). Put it behind a TLS-terminating reverse proxy (Caddy/nginx) if
  exposing it beyond a VPN, and set `WEB_SECURE_COOKIES=true` once it's
  HTTPS-only.
- HTML email bodies are rendered in a sandboxed `<iframe>` (`sandbox=""`,
  scripts disabled) so a captured message can't execute JavaScript in the
  admin's browser.
- The SMTP side never performs `AUTH` and accepts any `MAIL FROM` — it's an
  inbound-only capture point, not a relay. It will not forward or relay mail
  anywhere.
