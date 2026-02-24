#!/bin/bash
# ============================================================
#  rs-setup-cron.sh — Install backup cron jobs
#  Run once on the VPS to schedule automatic backups
# ============================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

log()   { echo -e "${GREEN}[✔]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✘]${NC} $1"; exit 1; }

[[ $EUID -ne 0 ]] && error "Must run as root"

SCRIPT_DIR="/root/rs-backup-scripts"

echo -e "${BLUE}══════════════════════════════════════${NC}"
echo -e "${BLUE}  RS Backup — Cron Setup${NC}"
echo -e "${BLUE}══════════════════════════════════════${NC}"
echo ""

# ── CONFIG PROMPTS ───────────────────────────────────────────
echo "Please provide your Mac Mini details for backup transfers:"
echo ""

read -rp "  Mac Mini IP or Tailscale IP: " MAC_IP
read -rp "  Mac Mini SSH user [rs_server]: " MAC_USER
MAC_USER="${MAC_USER:-rs_server}"
read -rp "  Mac Mini SSH key path [/root/.ssh/id_ed25519]: " MAC_KEY
MAC_KEY="${MAC_KEY:-/root/.ssh/id_ed25519}"
read -rp "  Backup path on Mac Mini [/Users/rs_server/server-backups/realtorstudio.io_vps_namecheap]: " MAC_PATH
MAC_PATH="${MAC_PATH:-/Users/rs_server/server-backups/realtorstudio.io_vps_namecheap}"

echo ""
echo "Backup schedule:"
echo "  - Every 12 hours (daily backups)"
echo "  - Sundays (weekly backups)"  
echo "  - 1st of each month (monthly backups)"
echo ""
read -rp "Continue? (y/N): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { warn "Aborted."; exit 0; }

# ── INSTALL SCRIPTS ──────────────────────────────────────────
mkdir -p "$SCRIPT_DIR"

# Update config in rs-backup.sh
sed -i "s|REMOTE_HOST=\"YOUR_MAC_MINI_IP_OR_TAILSCALE_IP\"|REMOTE_HOST=\"$MAC_IP\"|" "$SCRIPT_DIR/rs-backup.sh"
sed -i "s|REMOTE_USER=\"rs_server\"|REMOTE_USER=\"$MAC_USER\"|" "$SCRIPT_DIR/rs-backup.sh"
sed -i "s|REMOTE_SSH_KEY=\"/root/.ssh/id_ed25519\"|REMOTE_SSH_KEY=\"$MAC_KEY\"|" "$SCRIPT_DIR/rs-backup.sh"
sed -i "s|REMOTE_PATH=\"/Users/rs_server/server-backups/realtorstudio.io_vps_namecheap\"|REMOTE_PATH=\"$MAC_PATH\"|" "$SCRIPT_DIR/rs-backup.sh"

chmod +x "$SCRIPT_DIR/rs-backup.sh"
chmod +x "$SCRIPT_DIR/rs-restore.sh"

# ── SETUP SSH KEY TO MAC MINI ────────────────────────────────
echo ""
echo -e "${YELLOW}Setting up SSH key from VPS → Mac Mini...${NC}"
echo "This allows the VPS to SCP backups to your Mac Mini without a password."
echo ""

if [[ ! -f "$MAC_KEY" ]]; then
  log "Generating SSH key at $MAC_KEY"
  ssh-keygen -t ed25519 -f "$MAC_KEY" -N "" -C "rs-backup@$(hostname)"
fi

echo ""
echo "Copy this public key to your Mac Mini's authorized_keys:"
echo ""
cat "${MAC_KEY}.pub"
echo ""
echo "On your Mac Mini, run:"
echo "  mkdir -p ~/.ssh && chmod 700 ~/.ssh"
echo "  echo '$(cat ${MAC_KEY}.pub)' >> ~/.ssh/authorized_keys"
echo "  chmod 600 ~/.ssh/authorized_keys"
echo ""
read -rp "Press ENTER once you've added the key to your Mac Mini..."

# Test connection
echo ""
info() { echo -e "\033[0;36m[→]\033[0m $1"; }
info "Testing connection to Mac Mini..."
ssh -i "$MAC_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "${MAC_USER}@${MAC_IP}" "mkdir -p '$MAC_PATH/daily' '$MAC_PATH/weekly' '$MAC_PATH/monthly' && echo connected" \
  && log "Mac Mini connection successful!" \
  || { warn "Could not connect to Mac Mini. Check IP, user, and that SSH is enabled on Mac."; }

# ── INSTALL CRON JOBS ────────────────────────────────────────
echo ""
log "Installing cron jobs..."

# Remove any existing rs-backup cron entries
crontab -l 2>/dev/null | grep -v "rs-backup" > /tmp/current-cron || true

cat >> /tmp/current-cron <<EOF

# ── RS Backup — Auto-installed by rs-setup-cron.sh ──────────
# Daily backup every 12 hours (6am and 6pm UTC)
0 6,18 * * * /bin/bash $SCRIPT_DIR/rs-backup.sh >> /var/log/rs-backup.log 2>&1

# Note: weekly (Sunday) and monthly (1st) are handled automatically
# inside rs-backup.sh based on the day — no separate cron needed
EOF

crontab /tmp/current-cron
rm /tmp/current-cron

log "Cron jobs installed"

# ── VERIFY ───────────────────────────────────────────────────
echo ""
echo -e "${GREEN}══════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅ Backup System Ready${NC}"
echo -e "${GREEN}══════════════════════════════════════${NC}"
echo ""
echo "Scripts installed:  $SCRIPT_DIR/"
echo "Backup schedule:    Every 12h (6am + 6pm UTC)"
echo "Retention:          7 daily / 4 weekly / 3 monthly"
echo "Remote destination: ${MAC_USER}@${MAC_IP}:${MAC_PATH}"
echo "Log file:           /var/log/rs-backup.log"
echo ""
echo "Commands:"
echo "  Run backup now:     bash $SCRIPT_DIR/rs-backup.sh"
echo "  Dry run:            bash $SCRIPT_DIR/rs-backup.sh --dry-run"
echo "  Restore backup:     bash $SCRIPT_DIR/rs-restore.sh restore <file.tar.gz>"
echo "  Clone to server:    bash $SCRIPT_DIR/rs-restore.sh mirror <user@host>"
echo "  View cron jobs:     crontab -l"
echo "  View backup log:    tail -f /var/log/rs-backup.log"
echo ""
read -rp "Run a test backup now? (y/N): " TEST
[[ "$TEST" =~ ^[Yy]$ ]] && bash "$SCRIPT_DIR/rs-backup.sh" --dry-run
