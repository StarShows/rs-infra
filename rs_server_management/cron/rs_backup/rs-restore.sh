#!/bin/bash
# ============================================================
#  rs-restore.sh — Server Restore + Mirror/Clone Tool
#  realtorstudio.io | Namecheap VPS (AlmaLinux 9 / cPanel)
#
#  Modes:
#   restore   Restore backup to THIS server
#   mirror    Deploy current server state as 1:1 clone to any SSH destination
#
#  Usage:
#   bash rs-restore.sh restore <backup.tar.gz>
#   bash rs-restore.sh mirror  <user@destination-ip>
# ============================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()    { echo -e "${GREEN}[✔]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[✘]${NC} $1"; exit 1; }
info()   { echo -e "${CYAN}[→]${NC} $1"; }
header() { echo -e "\n${BLUE}══════════════════════════════════════${NC}"
           echo -e "${BLUE}  $1${NC}"
           echo -e "${BLUE}══════════════════════════════════════${NC}\n"; }

confirm() {
  echo -e "${YELLOW}$1${NC}"
  read -rp "Type YES to confirm: " REPLY
  [[ "$REPLY" == "YES" ]] || { warn "Aborted."; exit 0; }
}

[[ $EUID -ne 0 ]] && error "Must run as root"

MODE="${1:-}"
[[ -z "$MODE" ]] && {
  echo ""
  echo -e "${BOLD}Usage:${NC}"
  echo "  bash rs-restore.sh restore <backup.tar.gz>   # Restore to this server"
  echo "  bash rs-restore.sh mirror  <user@host>        # Clone to new server"
  echo ""
  exit 1
}

# ════════════════════════════════════════════════════════════
#  RESTORE MODE
# ════════════════════════════════════════════════════════════
if [[ "$MODE" == "restore" ]]; then

  BACKUP_FILE="${2:-}"
  [[ -z "$BACKUP_FILE" ]] && error "Usage: bash rs-restore.sh restore <backup.tar.gz>"
  [[ ! -f "$BACKUP_FILE" ]] && error "Backup file not found: $BACKUP_FILE"

  header "RS Restore — $(date)"

  # Show manifest before proceeding
  info "Reading manifest from backup..."
  MANIFEST=$(tar -xzOf "$BACKUP_FILE" --wildcards "*/MANIFEST.txt" 2>/dev/null || echo "No manifest found")
  echo ""
  echo "$MANIFEST"
  echo ""

  confirm "⚠  This will OVERWRITE files on this server with backup contents. Continue?"

  RESTORE_TMP="/root/rs-restore-tmp"
  mkdir -p "$RESTORE_TMP"

  header "Step 1: Extracting Backup"
  info "Extracting $BACKUP_FILE..."
  tar -xzf "$BACKUP_FILE" -C "$RESTORE_TMP"
  BACKUP_DIR=$(ls "$RESTORE_TMP")
  WORK="$RESTORE_TMP/$BACKUP_DIR"
  log "Extracted to $WORK"

  header "Step 2: Restore Databases"

  if ls "$WORK/databases/all-databases_"*.sql.gz &>/dev/null; then
    DB_DUMP=$(ls "$WORK/databases/all-databases_"*.sql.gz | head -1)
    info "Restoring all databases from: $(basename $DB_DUMP)"
    confirm "⚠  This will overwrite ALL existing databases. Continue?"
    gunzip < "$DB_DUMP" | mysql
    log "Databases restored"
  else
    warn "No database dump found — skipping DB restore"
  fi

  # MongoDB
  if ls "$WORK/databases/mongodb_"*.tar.gz &>/dev/null; then
    MONGO_DUMP=$(ls "$WORK/databases/mongodb_"*.tar.gz | head -1)
    info "Restoring MongoDB from: $(basename $MONGO_DUMP)"
    tar -xzf "$MONGO_DUMP" -C "$WORK/databases/"
    MONGO_DIR=$(basename "$MONGO_DUMP" .tar.gz)
    mongorestore "$WORK/databases/$MONGO_DIR" --drop
    log "MongoDB restored"
  fi

  header "Step 3: Restore Filesystem"

  for ARCHIVE in "$WORK/filesystem/"*.tar.gz; do
    [[ -f "$ARCHIVE" ]] || continue
    FILENAME=$(basename "$ARCHIVE" .tar.gz)
    # Convert dirname back to path (e.g. home_realtorstudio → /home/realtorstudio)
    ORIG_PATH="/$(echo "$FILENAME" | tr '_' '/')"
    info "Restoring: $ORIG_PATH from $(basename $ARCHIVE)"
    tar -xzf "$ARCHIVE" -C / --ignore-failed-read 2>/dev/null || warn "Some files may have failed: $ARCHIVE"
    log "  Restored: $ORIG_PATH"
  done

  header "Step 4: Restore SSH Config"
  if [[ -f "$WORK/system-info/sshd_config" ]]; then
    cp "$WORK/system-info/sshd_config" /etc/ssh/sshd_config
    [[ -f "$WORK/system-info/000-cpanel-options.conf" ]] && \
      cp "$WORK/system-info/000-cpanel-options.conf" /etc/ssh/sshd_config.d/
    systemctl restart sshd
    log "SSH config restored and reloaded"
  fi

  header "Step 5: Restore Crontabs"
  for CRON in "$WORK/system-info/crontab-"*.txt; do
    [[ -f "$CRON" ]] || continue
    USER=$(basename "$CRON" .txt | sed 's/crontab-//')
    crontab -u "$USER" "$CRON" 2>/dev/null && log "Crontab restored for: $USER" || warn "Failed crontab for: $USER"
  done

  # Cleanup
  rm -rf "$RESTORE_TMP"

  header "✅ Restore Complete"
  echo ""
  echo -e "  ${GREEN}Restored from:${NC} $BACKUP_FILE"
  echo -e "  ${YELLOW}Recommended:${NC}   Reboot the server to apply all changes"
  echo ""
  read -rp "Reboot now? (y/N): " REBOOT
  [[ "$REBOOT" =~ ^[Yy]$ ]] && reboot

fi

# ════════════════════════════════════════════════════════════
#  MIRROR / CLONE MODE
# ════════════════════════════════════════════════════════════
if [[ "$MODE" == "mirror" ]]; then

  DEST="${2:-}"
  [[ -z "$DEST" ]] && error "Usage: bash rs-restore.sh mirror <user@host>"

  # Parse user and host
  DEST_USER=$(echo "$DEST" | cut -d@ -f1)
  DEST_HOST=$(echo "$DEST" | cut -d@ -f2)

  header "RS Mirror — Clone to $DEST_HOST"

  echo ""
  echo -e "${RED}${BOLD}⚠  WARNING: DESTRUCTIVE OPERATION${NC}"
  echo ""
  echo "This will perform a 1:1 clone of this server to:"
  echo ""
  echo -e "  Destination: ${BOLD}${DEST}${NC}"
  echo ""
  echo "The following will be OVERWRITTEN on the destination:"
  echo "  • /home/realtorstudio (all websites, mail, files)"
  echo "  • /etc (all system config including SSH, PAM, nginx, etc.)"
  echo "  • /root (root home directory)"
  echo "  • /var/www (web root)"
  echo "  • All MySQL/MariaDB databases"
  echo "  • MongoDB databases"
  echo "  • Crontabs"
  echo ""
  echo -e "${YELLOW}The destination server's existing data will be REPLACED.${NC}"
  echo ""

  # Override prompts
  echo -e "${BOLD}Configuration Overrides (press ENTER to use source value):${NC}"
  echo ""

  read -rp "  Override hostname? [$(hostname)]: " NEW_HOSTNAME
  NEW_HOSTNAME="${NEW_HOSTNAME:-$(hostname)}"

  read -rp "  Skip SSH key transfer? (y/N): " SKIP_SSH_KEYS
  read -rp "  Skip cPanel/WHM config? (y/N): " SKIP_CPANEL
  read -rp "  Skip database transfer? (y/N): " SKIP_DB
  read -rp "  Custom SSH port on destination? [22]: " DEST_PORT
  DEST_PORT="${DEST_PORT:-22}"

  echo ""
  confirm "⚠  Type YES to begin 1:1 clone to ${DEST_HOST}"

  SSH_OPTS="-o StrictHostKeyChecking=no -p $DEST_PORT"
  SCP_OPTS="-o StrictHostKeyChecking=no -P $DEST_PORT"

  # Verify destination is reachable
  info "Testing connection to $DEST..."
  ssh $SSH_OPTS "$DEST" "echo connected" &>/dev/null || error "Cannot connect to $DEST. Check SSH access."
  log "Destination reachable"

  header "Step 1: Install Dependencies on Destination"
  ssh $SSH_OPTS "$DEST" "
    yum install epel-release -y &>/dev/null
    yum install rsync google-authenticator -y &>/dev/null
    echo done
  "
  log "Dependencies ready on destination"

  header "Step 2: Sync Filesystem"

  RSYNC_EXCLUDES=(
    "--exclude=/home/realtorstudio/tmp"
    "--exclude=/home/realtorstudio/softaculous_backups"
    "--exclude=/home/realtorstudio/backup-*.tar.gz"
    "--exclude=/root/rs-backups"
    "--exclude=/proc"
    "--exclude=/sys"
    "--exclude=/dev"
    "--exclude=/run"
    "--exclude=/tmp"
  )

  SYNC_DIRS=(
    "/home/realtorstudio"
    "/etc"
    "/root"
    "/var/www"
  )

  if [[ "$SKIP_CPANEL" =~ ^[Yy]$ ]]; then
    RSYNC_EXCLUDES+=("--exclude=/etc/cpanel" "--exclude=/etc/whm*")
    warn "Skipping cPanel config sync"
  fi

  if [[ "$SKIP_SSH_KEYS" =~ ^[Yy]$ ]]; then
    RSYNC_EXCLUDES+=("--exclude=/root/.ssh")
    warn "Skipping SSH key sync"
  fi

  for DIR in "${SYNC_DIRS[@]}"; do
    [[ -d "$DIR" ]] || continue
    info "Syncing $DIR → $DEST:$DIR"
    rsync -azP --delete \
      "${RSYNC_EXCLUDES[@]}" \
      -e "ssh $SSH_OPTS" \
      "$DIR/" \
      "$DEST:$DIR/"
    log "  Synced: $DIR"
  done

  header "Step 3: Mirror Databases"

  if [[ ! "$SKIP_DB" =~ ^[Yy]$ ]]; then

    # MySQL
    if command -v mysqldump &>/dev/null; then
      info "Transferring MySQL databases..."
      mysqldump --all-databases --single-transaction --routines --triggers --events \
        --add-drop-database 2>/dev/null \
        | ssh $SSH_OPTS "$DEST" "mysql"
      log "MySQL databases mirrored"
    fi

    # MongoDB
    if command -v mongodump &>/dev/null; then
      info "Transferring MongoDB..."
      MONGO_TMP="/tmp/rs-mirror-mongo-$(date +%s)"
      mongodump --out "$MONGO_TMP" --quiet 2>/dev/null
      rsync -az -e "ssh $SSH_OPTS" "$MONGO_TMP/" "$DEST:/tmp/rs-mirror-mongo/"
      ssh $SSH_OPTS "$DEST" "mongorestore /tmp/rs-mirror-mongo/ --drop --quiet 2>/dev/null; rm -rf /tmp/rs-mirror-mongo"
      rm -rf "$MONGO_TMP"
      log "MongoDB mirrored"
    fi

  else
    warn "Skipping database transfer"
  fi

  header "Step 4: Mirror Crontabs"
  crontab -l 2>/dev/null | ssh $SSH_OPTS "$DEST" "crontab -" || warn "No root crontab to mirror"
  log "Crontabs mirrored"

  header "Step 5: Apply Server Config on Destination"

  ssh $SSH_OPTS "$DEST" "
    # Set hostname
    hostnamectl set-hostname '$NEW_HOSTNAME' 2>/dev/null || true

    # Reload SSH
    systemctl restart sshd 2>/dev/null || true

    # Reload services if they exist
    systemctl restart nginx 2>/dev/null || true
    systemctl restart httpd 2>/dev/null || true
    systemctl restart mariadb 2>/dev/null || true
    systemctl restart mongod 2>/dev/null || true

    echo 'Services restarted'
  "
  log "Destination server configured"

  header "✅ Mirror Complete"
  echo ""
  echo -e "  ${GREEN}Cloned to:${NC}    $DEST"
  echo -e "  ${GREEN}Hostname:${NC}     $NEW_HOSTNAME"
  echo -e "  ${YELLOW}Next steps:${NC}"
  echo "    1. Update DNS to point to new server IP"
  echo "    2. Verify all sites load correctly"
  echo "    3. Test SSH + 2FA on new server"
  echo "    4. Update any hardcoded IPs in configs"
  echo ""

fi
