#!/bin/bash
# ============================================================
#  rs-backup.sh — Full Server Backup + Smart Retention
#  realtorstudio.io | Namecheap VPS (AlmaLinux 9 / cPanel)
#
#  Features:
#   - Full filesystem + database backup
#   - Smart retention: 7 daily, 4 weekly, 3 monthly
#   - Downloads backup to Mac Mini via SCP
#   - Manifest file for easy restore reference
#
#  Usage:
#   bash rs-backup.sh              # Run backup
#   bash rs-backup.sh --dry-run    # Preview without executing
# ============================================================

set -euo pipefail

# ── CONFIG ────────────────────────────────────────────────────
BACKUP_NAME="realtorstudio-vps"
BACKUP_BASE="/root/rs-backups"
TMP_DIR="/root/rs-backups/tmp"
LOG_FILE="/var/log/rs-backup.log"

# Remote destination (Mac Mini)
REMOTE_USER="rs_server"
REMOTE_HOST="YOUR_MAC_MINI_IP_OR_TAILSCALE_IP"
REMOTE_PATH="/Users/rs_server/server-backups/realtorstudio.io_vps_namecheap"
REMOTE_SSH_KEY="/root/.ssh/id_ed25519"  # SSH key to Mac Mini

# What to backup
BACKUP_DIRS=(
  "/home/realtorstudio"
  "/etc"
  "/var/www"
  "/root"
)

# Dirs to exclude from backup (saves space)
EXCLUDE_DIRS=(
  "/home/realtorstudio/tmp"
  "/home/realtorstudio/softaculous_backups"
  "/home/realtorstudio/backup-*.tar.gz"
  "/root/rs-backups"
)

# Database config (reads from .my.cnf if exists, else prompts)
DB_ALL=true   # Backup all databases
# DB_NAMES=("wordpress_db" "crm_db")  # Or specify specific DBs

# Retention policy
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=3

# ── COLORS ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()    { echo -e "${GREEN}[✔ $(date '+%H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"; }
warn()   { echo -e "${YELLOW}[! $(date '+%H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"; }
error()  { echo -e "${RED}[✘ $(date '+%H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"; exit 1; }
info()   { echo -e "${CYAN}[→ $(date '+%H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"; }
header() { echo -e "\n${BLUE}══════════════════════════════════════${NC}" | tee -a "$LOG_FILE"
           echo -e "${BLUE}  $1${NC}" | tee -a "$LOG_FILE"
           echo -e "${BLUE}══════════════════════════════════════${NC}" | tee -a "$LOG_FILE"; }

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true && warn "DRY RUN MODE — no files will be written"

run() {
  if $DRY_RUN; then
    echo -e "${YELLOW}  [DRY] $*${NC}"
  else
    eval "$@"
  fi
}

# ── SETUP ────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Must run as root"

DATE=$(date '+%Y-%m-%d_%H-%M-%S')
DAY_OF_WEEK=$(date '+%u')   # 1=Mon ... 7=Sun
DAY_OF_MONTH=$(date '+%d')

# Determine backup type for retention labeling
if [[ "$DAY_OF_MONTH" == "01" ]]; then
  BACKUP_TYPE="monthly"
elif [[ "$DAY_OF_WEEK" == "7" ]]; then
  BACKUP_TYPE="weekly"
else
  BACKUP_TYPE="daily"
fi

BACKUP_FILENAME="${BACKUP_NAME}_${BACKUP_TYPE}_${DATE}"
WORK_DIR="${TMP_DIR}/${BACKUP_FILENAME}"

header "RS Backup — $(date '+%Y-%m-%d %H:%M:%S') [$BACKUP_TYPE]"

run "mkdir -p '$WORK_DIR/databases' '$WORK_DIR/filesystem' '$BACKUP_BASE/daily' '$BACKUP_BASE/weekly' '$BACKUP_BASE/monthly'"

# ── SYSTEM INFO SNAPSHOT ─────────────────────────────────────
header "Step 1: System Snapshot"

info "Capturing system state..."
run "mkdir -p '$WORK_DIR/system-info'"

if ! $DRY_RUN; then
cat > "$WORK_DIR/system-info/server-info.txt" <<EOF
========================================
SERVER SNAPSHOT — $(date)
========================================
Hostname:     $(hostname)
IP Address:   $(hostname -I | awk '{print $1}')
OS:           $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)
Kernel:       $(uname -r)
Uptime:       $(uptime -p)
Disk Usage:   $(df -h / | tail -1)
Memory:       $(free -h | grep Mem)
cPanel:       $(cat /usr/local/cpanel/version 2>/dev/null || echo "unknown")

BACKUP TYPE:  $BACKUP_TYPE
BACKUP DATE:  $DATE
EOF

# Capture installed packages list
rpm -qa --queryformat '%{NAME} %{VERSION}\n' | sort > "$WORK_DIR/system-info/installed-packages.txt"

# Capture crontabs
crontab -l > "$WORK_DIR/system-info/root-crontab.txt" 2>/dev/null || true
ls /var/spool/cron/ | while read user; do
  crontab -l -u "$user" > "$WORK_DIR/system-info/crontab-${user}.txt" 2>/dev/null || true
done

# Capture network config
ip addr > "$WORK_DIR/system-info/network.txt" 2>/dev/null || true
ip route >> "$WORK_DIR/system-info/network.txt" 2>/dev/null || true
ss -tlnp >> "$WORK_DIR/system-info/network.txt" 2>/dev/null || true

# Capture firewall rules
firewall-cmd --list-all > "$WORK_DIR/system-info/firewall.txt" 2>/dev/null || true
iptables -L -n > "$WORK_DIR/system-info/iptables.txt" 2>/dev/null || true

# SSH config snapshot
cp /etc/ssh/sshd_config "$WORK_DIR/system-info/sshd_config" 2>/dev/null || true
cp /etc/ssh/sshd_config.d/000-cpanel-options.conf "$WORK_DIR/system-info/000-cpanel-options.conf" 2>/dev/null || true

log "System snapshot captured"
fi

# ── DATABASE BACKUP ──────────────────────────────────────────
header "Step 2: Database Backup"

if command -v mysqldump &>/dev/null || command -v /usr/bin/mysqldump &>/dev/null; then
  MYSQLDUMP=$(command -v mysqldump || echo "/usr/bin/mysqldump")

  if $DB_ALL; then
    info "Dumping all databases..."
    run "$MYSQLDUMP --all-databases --single-transaction --routines --triggers --events \
      --add-drop-database --flush-logs 2>/dev/null \
      | gzip > '$WORK_DIR/databases/all-databases_${DATE}.sql.gz'"
    log "All databases dumped"

    # Also dump each DB individually for selective restore
    if ! $DRY_RUN; then
      DBS=$(mysql -e "SHOW DATABASES;" 2>/dev/null | grep -Ev "^(Database|information_schema|performance_schema|sys)$" || true)
      for DB in $DBS; do
        info "  Dumping: $DB"
        $MYSQLDUMP "$DB" --single-transaction --routines --triggers \
          --add-drop-table 2>/dev/null \
          | gzip > "$WORK_DIR/databases/${DB}_${DATE}.sql.gz" || warn "  Failed to dump $DB"
      done
    fi
  fi
  log "Database backup complete"
else
  warn "mysqldump not found — skipping database backup"
fi

# MongoDB backup
if command -v mongodump &>/dev/null; then
  info "Dumping MongoDB..."
  run "mongodump --out '$WORK_DIR/databases/mongodb_${DATE}' --quiet 2>/dev/null"
  run "tar -czf '$WORK_DIR/databases/mongodb_${DATE}.tar.gz' -C '$WORK_DIR/databases' 'mongodb_${DATE}' 2>/dev/null"
  run "rm -rf '$WORK_DIR/databases/mongodb_${DATE}'"
  log "MongoDB dump complete"
fi

# ── FILESYSTEM BACKUP ────────────────────────────────────────
header "Step 3: Filesystem Backup"

# Build exclude args
EXCLUDE_ARGS=""
for DIR in "${EXCLUDE_DIRS[@]}"; do
  EXCLUDE_ARGS="$EXCLUDE_ARGS --exclude='$DIR'"
done

for SRC in "${BACKUP_DIRS[@]}"; do
  if [[ -d "$SRC" ]]; then
    DIRNAME=$(echo "$SRC" | tr '/' '_' | sed 's/^_//')
    info "Archiving: $SRC"
    run "tar -czf '$WORK_DIR/filesystem/${DIRNAME}.tar.gz' \
      $EXCLUDE_ARGS \
      --ignore-failed-read \
      '$SRC' 2>/dev/null || true"
    log "  Done: $SRC → ${DIRNAME}.tar.gz"
  else
    warn "Directory not found, skipping: $SRC"
  fi
done

# ── MANIFEST ────────────────────────────────────────────────
header "Step 4: Building Manifest"

if ! $DRY_RUN; then
cat > "$WORK_DIR/MANIFEST.txt" <<EOF
========================================
BACKUP MANIFEST
========================================
Name:         $BACKUP_FILENAME
Type:         $BACKUP_TYPE
Date:         $(date)
Server:       $(hostname) ($(hostname -I | awk '{print $1'}))
OS:           $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)

CONTENTS:
$(find "$WORK_DIR" -type f | sort | sed "s|$WORK_DIR/||")

SIZES:
$(du -sh "$WORK_DIR"/* 2>/dev/null)

RESTORE INSTRUCTIONS:
  See rs-restore.sh for automated restore
  Manual: extract tar.gz files to their original paths
  DB:     gunzip < databases/all-databases_*.sql.gz | mysql

BACKUP DIRS:
$(printf '%s\n' "${BACKUP_DIRS[@]}")

EXCLUDED:
$(printf '%s\n' "${EXCLUDE_DIRS[@]}")
========================================
EOF
log "Manifest created"
fi

# ── PACKAGE & COMPRESS ───────────────────────────────────────
header "Step 5: Packaging"

FINAL_ARCHIVE="${BACKUP_BASE}/${BACKUP_TYPE}/${BACKUP_FILENAME}.tar.gz"

info "Compressing backup package..."
run "tar -czf '$FINAL_ARCHIVE' -C '$TMP_DIR' '$BACKUP_FILENAME'"
run "rm -rf '$WORK_DIR'"

if ! $DRY_RUN; then
  SIZE=$(du -sh "$FINAL_ARCHIVE" | cut -f1)
  log "Backup packaged: $FINAL_ARCHIVE ($SIZE)"
fi

# ── TRANSFER TO MAC MINI ─────────────────────────────────────
header "Step 6: Transferring to Mac Mini"

REMOTE_TYPE_PATH="${REMOTE_PATH}/${BACKUP_TYPE}"

info "Syncing to ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_TYPE_PATH}/"

run "ssh -i '$REMOTE_SSH_KEY' -o StrictHostKeyChecking=no \
  '${REMOTE_USER}@${REMOTE_HOST}' \
  'mkdir -p \"${REMOTE_TYPE_PATH}\"'"

run "scp -i '$REMOTE_SSH_KEY' \
  '$FINAL_ARCHIVE' \
  '${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_TYPE_PATH}/'"

log "Transfer complete"

# ── RETENTION CLEANUP ────────────────────────────────────────
header "Step 7: Retention Cleanup"

cleanup_old() {
  local TYPE=$1
  local KEEP=$2
  local DIR="${BACKUP_BASE}/${TYPE}"
  local REMOTE_DIR="${REMOTE_PATH}/${TYPE}"

  info "Cleaning $TYPE backups (keeping $KEEP)..."

  # Local cleanup
  if ! $DRY_RUN; then
    ls -1t "$DIR"/*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | while read f; do
      rm -f "$f"
      log "  Removed local: $(basename $f)"
    done
  fi

  # Remote cleanup
  run "ssh -i '$REMOTE_SSH_KEY' -o StrictHostKeyChecking=no \
    '${REMOTE_USER}@${REMOTE_HOST}' \
    'ls -1t \"${REMOTE_DIR}\"/*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f && echo cleaned'"
}

cleanup_old "daily"   $KEEP_DAILY
cleanup_old "weekly"  $KEEP_WEEKLY
cleanup_old "monthly" $KEEP_MONTHLY

log "Retention cleanup complete"

# ── SUMMARY ─────────────────────────────────────────────────
header "✅ Backup Complete"

if ! $DRY_RUN; then
  echo ""
  echo -e "  ${GREEN}Backup:${NC}    $BACKUP_FILENAME"
  echo -e "  ${GREEN}Type:${NC}      $BACKUP_TYPE"
  echo -e "  ${GREEN}Size:${NC}      $(du -sh "$FINAL_ARCHIVE" | cut -f1)"
  echo -e "  ${GREEN}Local:${NC}     $FINAL_ARCHIVE"
  echo -e "  ${GREEN}Remote:${NC}    ${REMOTE_HOST}:${REMOTE_TYPE_PATH}/"
  echo -e "  ${GREEN}Log:${NC}       $LOG_FILE"
  echo ""
fi

exit 0
