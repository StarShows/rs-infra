#!/bin/bash
# ============================================================
#  quickstart.sh — SSH 2FA Hardening Toolkit
#  realtorstudio.io | Namecheap VPS (AlmaLinux 9 + cPanel)
#
#  Files in this toolkit:
#    quickstart.sh          — This menu (you are here)
#    setup-2fa-ssh.sh       — One-drop server hardening script
#    SSH_2FA_SOP.docx       — Full step-by-step SOP document
#
#  Usage: bash quickstart.sh
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/setup-2fa-ssh.sh"
SOP_DOC="$SCRIPT_DIR/SSH_2FA_SOP.docx"

clear

print_header() {
  echo -e "${BLUE}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════════╗"
  echo "  ║         SSH 2FA HARDENING TOOLKIT                   ║"
  echo "  ║         realtorstudio.io — Namecheap VPS            ║"
  echo "  ╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

print_files() {
  echo -e "${CYAN}${BOLD}  Toolkit Files:${NC}"
  echo ""

  if [[ -f "$SETUP_SCRIPT" ]]; then
    echo -e "  ${GREEN}✔${NC}  setup-2fa-ssh.sh     — Server hardening script"
  else
    echo -e "  ${RED}✘${NC}  setup-2fa-ssh.sh     — ${RED}NOT FOUND${NC}"
  fi

  if [[ -f "$SOP_DOC" ]]; then
    echo -e "  ${GREEN}✔${NC}  SSH_2FA_SOP.docx     — Full SOP documentation"
  else
    echo -e "  ${YELLOW}!${NC}  SSH_2FA_SOP.docx     — ${YELLOW}Not found (optional for server use)${NC}"
  fi

  echo -e "  ${GREEN}✔${NC}  quickstart.sh        — This menu"
  echo ""
}

print_menu() {
  echo -e "${BOLD}  What would you like to do?${NC}"
  echo ""
  echo -e "  ${YELLOW}[1]${NC}  Run full 2FA setup on this server"
  echo -e "  ${YELLOW}[2]${NC}  Check current SSH + 2FA status"
  echo -e "  ${YELLOW}[3]${NC}  Emergency: restore SSH access (fix lockout)"
  echo -e "  ${YELLOW}[4]${NC}  Check fail2ban status"
  echo -e "  ${YELLOW}[5]${NC}  Re-generate Google Authenticator TOTP"
  echo -e "  ${YELLOW}[6]${NC}  Download this toolkit to a server via SCP"
  echo -e "  ${YELLOW}[7]${NC}  View quick reference guide"
  echo -e "  ${YELLOW}[q]${NC}  Quit"
  echo ""
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This option requires root. Re-run with: sudo bash quickstart.sh${NC}"
    return 1
  fi
  return 0
}

# ── Option 1: Full Setup ──────────────────────────────────
run_setup() {
  check_root || return
  if [[ ! -f "$SETUP_SCRIPT" ]]; then
    echo -e "${RED}setup-2fa-ssh.sh not found in $SCRIPT_DIR${NC}"
    return
  fi
  echo ""
  echo -e "${YELLOW}This will run the full 2FA hardening setup on this server.${NC}"
  echo -e "${RED}Make sure you have a backup terminal session open before proceeding!${NC}"
  echo ""
  read -rp "Continue? (y/N): " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; return; }
  bash "$SETUP_SCRIPT"
}

# ── Option 2: Status Check ───────────────────────────────
check_status() {
  check_root || return
  echo ""
  echo -e "${BOLD}── SSH Daemon Status ──────────────────────────────────${NC}"
  systemctl is-active sshd &>/dev/null && echo -e "${GREEN}✔ sshd is running${NC}" || echo -e "${RED}✘ sshd is NOT running${NC}"

  echo ""
  echo -e "${BOLD}── Active SSH Config ──────────────────────────────────${NC}"
  sshd -T 2>/dev/null | grep -E "passwordauthentication|kbdinteractiveauthentication|usepam|pubkeyauthentication|authenticationmethods" | while read line; do
    key=$(echo "$line" | awk '{print $1}')
    val=$(echo "$line" | awk '{print $2}')
    if [[ "$val" == "yes" ]]; then
      echo -e "  ${GREEN}✔${NC}  $line"
    elif [[ "$val" == "no" ]]; then
      echo -e "  ${YELLOW}!${NC}  $line"
    else
      echo -e "  ${CYAN}→${NC}  $line"
    fi
  done

  echo ""
  echo -e "${BOLD}── PAM Config ─────────────────────────────────────────${NC}"
  if grep -q "pam_google_authenticator" /etc/pam.d/sshd 2>/dev/null; then
    GA_LINE=$(grep "pam_google_authenticator" /etc/pam.d/sshd)
    if echo "$GA_LINE" | grep -q "^#"; then
      echo -e "  ${RED}✘ google-authenticator is COMMENTED OUT in PAM${NC}"
    else
      echo -e "  ${GREEN}✔ google-authenticator active in PAM${NC}"
    fi
  else
    echo -e "  ${RED}✘ google-authenticator NOT found in /etc/pam.d/sshd${NC}"
  fi

  if grep -q "^auth.*substack.*password-auth" /etc/pam.d/sshd 2>/dev/null; then
    echo -e "  ${RED}✘ password-auth substack is active (will prompt for password)${NC}"
  else
    echo -e "  ${GREEN}✔ password-auth substack disabled${NC}"
  fi

  echo ""
  echo -e "${BOLD}── Google Authenticator ───────────────────────────────${NC}"
  if [[ -f /root/.google_authenticator ]]; then
    echo -e "  ${GREEN}✔ /root/.google_authenticator exists${NC}"
  else
    echo -e "  ${RED}✘ /root/.google_authenticator NOT found — run setup first${NC}"
  fi

  echo ""
  echo -e "${BOLD}── SSH Keys ────────────────────────────────────────────${NC}"
  if [[ -s /root/.ssh/authorized_keys ]]; then
    KEY_COUNT=$(wc -l < /root/.ssh/authorized_keys)
    echo -e "  ${GREEN}✔ $KEY_COUNT authorized key(s) found${NC}"
  else
    echo -e "  ${RED}✘ No authorized_keys found — password auth only!${NC}"
  fi

  echo ""
  echo -e "${BOLD}── cPanel Override File ────────────────────────────────${NC}"
  CPANEL_CONF="/etc/ssh/sshd_config.d/000-cpanel-options.conf"
  if grep -q "ChallengeResponseAuthentication yes" "$CPANEL_CONF" 2>/dev/null; then
    echo -e "  ${GREEN}✔ ChallengeResponseAuthentication yes set in cPanel conf${NC}"
  else
    echo -e "  ${RED}✘ ChallengeResponseAuthentication not overridden — 2FA will break!${NC}"
  fi
}

# ── Option 3: Emergency Restore ──────────────────────────
emergency_restore() {
  check_root || return
  echo ""
  echo -e "${RED}${BOLD}⚠ EMERGENCY SSH RESTORE${NC}"
  echo ""
  echo "This will temporarily re-enable password authentication"
  echo "so you can SSH back in after a lockout."
  echo ""
  read -rp "Are you sure? (y/N): " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; return; }

  # Re-enable password auth in all relevant files
  sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null || true
  sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config.d/000-cpanel-options.conf 2>/dev/null || true

  # Comment out google-authenticator in PAM
  sed -i 's/^auth required pam_google_authenticator/#auth required pam_google_authenticator/' /etc/pam.d/sshd 2>/dev/null || true

  systemctl restart sshd

  echo ""
  echo -e "${GREEN}✔ SSH restored to password-only mode${NC}"
  echo -e "${YELLOW}You can now SSH in with: ssh root@$(hostname -I | awk '{print $1}')${NC}"
  echo ""
  echo -e "${YELLOW}Remember to re-run the setup once you're back in!${NC}"
}

# ── Option 4: Fail2Ban Status ─────────────────────────────
check_fail2ban() {
  check_root || return
  echo ""
  if systemctl is-active fail2ban &>/dev/null; then
    echo -e "${GREEN}✔ fail2ban is running${NC}"
    echo ""
    fail2ban-client status sshd 2>/dev/null || echo "SSH jail not configured yet."
  else
    echo -e "${RED}✘ fail2ban is not running${NC}"
    echo ""
    read -rp "Start and enable fail2ban now? (y/N): " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] && systemctl enable fail2ban --now && echo -e "${GREEN}✔ fail2ban started${NC}"
  fi
}

# ── Option 5: Re-generate TOTP ───────────────────────────
regen_totp() {
  check_root || return
  echo ""
  echo -e "${YELLOW}This will overwrite your existing Google Authenticator config.${NC}"
  echo -e "${RED}Make sure you're ready to scan the new QR code before continuing!${NC}"
  echo ""
  read -rp "Continue? (y/N): " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; return; }
  google-authenticator -t -d -f -r 3 -R 30 -w 3
  echo ""
  echo -e "${GREEN}✔ New TOTP configured. Update your authenticator app now.${NC}"
  echo -e "${YELLOW}Save your new scratch codes in a secure location!${NC}"
}

# ── Option 6: SCP Toolkit to Server ──────────────────────
scp_to_server() {
  echo ""
  echo -e "${BOLD}Deploy this toolkit to a new server${NC}"
  echo ""
  read -rp "  Server IP or hostname: " SERVER
  read -rp "  Remote user [root]: " REMOTE_USER
  REMOTE_USER="${REMOTE_USER:-root}"
  read -rp "  Remote destination path [/root/]: " REMOTE_PATH
  REMOTE_PATH="${REMOTE_PATH:-/root/}"

  echo ""
  echo -e "Copying toolkit to ${REMOTE_USER}@${SERVER}:${REMOTE_PATH} ..."
  echo ""
  scp "$SCRIPT_DIR/quickstart.sh" \
      "$SCRIPT_DIR/setup-2fa-ssh.sh" \
      "${REMOTE_USER}@${SERVER}:${REMOTE_PATH}"

  echo ""
  echo -e "${GREEN}✔ Done! To run on the server:${NC}"
  echo -e "  ssh ${REMOTE_USER}@${SERVER}"
  echo -e "  bash ${REMOTE_PATH}quickstart.sh"
}

# ── Option 7: Quick Reference ─────────────────────────────
quick_reference() {
  clear
  echo -e "${BLUE}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════════╗"
  echo "  ║              QUICK REFERENCE                        ║"
  echo "  ╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  echo -e "${BOLD}  Login Flow (after setup):${NC}"
  echo "    ssh root@209.74.88.248"
  echo "    → Verification code: [6-digit TOTP]"
  echo "    → Logged in (no password prompt)"
  echo ""
  echo -e "${BOLD}  Key Files:${NC}"
  echo "    /etc/pam.d/sshd                              PAM auth config"
  echo "    /etc/ssh/sshd_config                         Main SSH config"
  echo "    /etc/ssh/sshd_config.d/000-cpanel-options.conf  cPanel overrides"
  echo "    /root/.google_authenticator                  TOTP secret"
  echo "    /root/.ssh/authorized_keys                   SSH public keys"
  echo "    /etc/fail2ban/jail.local                     Fail2ban config"
  echo ""
  echo -e "${BOLD}  Useful Commands:${NC}"
  echo "    systemctl restart sshd                       Restart SSH"
  echo "    systemctl status sshd                        Check SSH status"
  echo "    sshd -t                                      Validate config"
  echo "    sshd -T | grep kbdinteractive                Check active config"
  echo "    fail2ban-client status sshd                  Check banned IPs"
  echo "    journalctl -xeu sshd.service | tail -20      SSH error logs"
  echo ""
  echo -e "${BOLD}  Backup Access:${NC}"
  echo "    1. Keep current SSH session open during changes"
  echo "    2. WHM Terminal (Namecheap panel)"
  echo "    3. Namecheap KVM Console"
  echo ""
  echo -e "${BOLD}  AlmaLinux 9 / cPanel Gotchas:${NC}"
  echo "    • 50-redhat.conf disables keyboard-interactive by default"
  echo "    • Override in 000-cpanel-options.conf, NOT sshd_config"
  echo "    • Comment out 'auth substack password-auth' in pam.d/sshd"
  echo "    • AuthenticationMethods must go in 000-cpanel-options.conf"
  echo ""
}

# ── Main Loop ─────────────────────────────────────────────
while true; do
  clear
  print_header
  print_files
  print_menu

  read -rp "  Choose an option: " CHOICE
  echo ""

  case "$CHOICE" in
    1) run_setup ;;
    2) check_status ;;
    3) emergency_restore ;;
    4) check_fail2ban ;;
    5) regen_totp ;;
    6) scp_to_server ;;
    7) quick_reference ;;
    q|Q) echo -e "${GREEN}Goodbye!${NC}"; exit 0 ;;
    *) echo -e "${RED}Invalid option.${NC}" ;;
  esac

  echo ""
  read -rp "Press ENTER to return to menu..."
done