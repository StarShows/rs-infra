# rs-cli Quickstart

## First Time Setup (Mac Mini)

```bash
# 1. Install rs-cli
cp rs-cli /usr/local/bin/rs-cli
chmod +x /usr/local/bin/rs-cli

# 2. Copy default config
mkdir -p ~/.rs-cli
cp rs-cli-config.yaml ~/.rs-cli/config.yaml

# 3. Upload agent to VPS
scp rs-backup-agent.sh root@209.74.88.248:/root/rs-backup-agent.sh
ssh root@209.74.88.248 "chmod +x /root/rs-backup-agent.sh"

# 4. Install cron schedule (runs every 12 hours)
rs-cli cron
```

---

## Daily Commands

```bash
# Run a backup now
rs-cli backup

# List all backups
rs-cli list

# Check status + disk usage
rs-cli status

# Restore to live server (shows diff + requires confirmation)
rs-cli restore dest-209.74.88.248

# Restore to a different server
rs-cli restore dest-newserver.realtorstudio.io
```

---

## Backup Tiers & Retention

| Tier    | When                        | Keep  |
|---------|-----------------------------|-------|
| daily   | Every 12 hours              | 14    |
| weekly  | Every Sunday                | 8     |
| monthly | 1st of each month           | 3     |
| yearly  | January 1st                 | 2     |

Backups are stored at:
`~/server-backups/realtorstudio.io_vps_namecheap/{tier}/{timestamp}/`

Each backup contains:
- `home/`   — rsync of /home/realtorstudio
- `cpanel/` — cPanel full backup archive
- `mysql/`  — mysqldump of all databases
- `MANIFEST.txt` — backup metadata

---

## Restore Flow

1. `rs-cli restore dest-[host]`
2. Select backup from list
3. Review diff report (files added/deleted/changed)
4. Type `RESTORE` to confirm
5. Pre-restore safety backup is taken automatically
6. Files + databases are pushed to server

---

## Config

Edit `~/.rs-cli/config.yaml` then sync to VPS:
```bash
rs-cli config
```
