#!/usr/bin/env bash
# ============================================================
#  rs-backup-agent.sh — VPS-side backup agent
#  Runs on: Namecheap VPS (AlmaLinux 9)
#  Triggered by: rs-cli on Mac Mini
#  Usage: bash rs-backup-agent.sh --backup
# ============================================================

set -euo pipefail

LOG="/var/log/rs-backup-agent.log"
CONFIG="/root/.rs-cli/config.yaml"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
DUMP_DIR="/root/.rs-cli/mysql_dumps"
CPANEL_USER="realtorstudio"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [✔] $1" | tee -a "$LOG"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [!] $1" | tee -a "$LOG"; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [✘] $1" | tee -a "$LOG"; exit 1; }

# ── Load config ─────────────────────────────────────────────
if [[ -f "$CONFIG" ]]; then
  get_val() { grep "^$1:" "$CONFIG" | sed 's/^[^:]*: *//' | tr -d '"' | tr -d "'"; }
  CPANEL_USER=$(get_val "cpanel_user" 2>/dev/null || echo "realtorstudio")
fi

# ── Main backup routine ──────────────────────────────────────
do_backup() {
  log "=== rs-backup-agent START $TIMESTAMP ==="
  mkdir -p "$DUMP_DIR"

  # ── Step 1: cPanel full backup ───────────────────────────
  log "Step 1/3 — Generating cPanel full backup..."

  # Remove old cPanel backups (keep only latest)
  ls -t /home/$CPANEL_USER/backup-*.tar.gz 2>/dev/null | tail -n +2 | xargs rm -f 2>/dev/null || true

  # Trigger cPanel backup via CLI
  if command -v /scripts/pkgacct &>/dev/null; then
    /scripts/pkgacct --skiphomedir $CPANEL_USER /home/$CPANEL_USER 2>> "$LOG" || warn "pkgacct encountered issues"
    log "cPanel pkgacct backup complete"
  else
    warn "pkgacct not found — skipping cPanel backup"
  fi

  # ── Step 2: MySQL dump all databases ────────────────────
  log "Step 2/3 — Dumping all MySQL databases..."

  # Clean old dumps
  rm -f "$DUMP_DIR"/*.sql.gz 2>/dev/null || true

  # Get all databases (excluding system DBs)
  DATABASES=$(mysql -N -e "SHOW DATABASES;" 2>/dev/null | grep -v -E "^(information_schema|performance_schema|mysql|sys)$" || true)

  if [[ -z "$DATABASES" ]]; then
    warn "No user databases found or MySQL not accessible"
  else
    while IFS= read -r DB; do
      [[ -z "$DB" ]] && continue
      log "  Dumping: $DB"
      mysqldump --single-transaction --quick --lock-tables=false \
        "$DB" 2>> "$LOG" | gzip > "$DUMP_DIR/${DB}.sql.gz" \
        && log "  ✔ $DB dumped" \
        || warn "  ✘ Failed to dump $DB"
    done <<< "$DATABASES"
  fi

  # ── Step 3: Cleanup temp files ───────────────────────────
  log "Step 3/3 — Cleaning up tmp and old logs..."

  # Clear /home/user/tmp
  find /home/$CPANEL_USER/tmp -type f -mtime +1 -delete 2>/dev/null || true
  find /home/$CPANEL_USER/tmp -type d -empty -delete 2>/dev/null || true

  # Truncate large log files over 100MB
  find /home/$CPANEL_USER/logs -type f -size +100M -exec truncate -s 0 {} \; 2>/dev/null || true

  log "=== rs-backup-agent COMPLETE $TIMESTAMP ==="
}

# ── Entry point ──────────────────────────────────────────────
case "${1:---backup}" in
  --backup) do_backup ;;
  *) err "Unknown argument: $1" ;;
esac
