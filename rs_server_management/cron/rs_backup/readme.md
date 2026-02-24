# SSH 2FA Hardening Toolkit
### realtorstudio.io — Namecheap VPS (AlmaLinux 9 + cPanel)

---

## What's in This Folder

| File | Purpose |
|------|---------|
| `quickstart.sh` | Interactive menu — your main entry point for everything |
| `setup-2fa-ssh.sh` | One-drop automation script — run once on a fresh server |
| `SSH_2FA_SOP.docx` | Full step-by-step SOP with troubleshooting and checklists |

---

## Quick Start

### New Server Setup
Copy the toolkit to your server and run:
```bash
scp quickstart.sh setup-2fa-ssh.sh root@<server-ip>:~/
ssh root@<server-ip>
bash quickstart.sh
```
Then choose **Option 1** from the menu.

### Already Set Up — Just Need the Menu
```bash
bash quickstart.sh
```

---

## What the Setup Does

After running `setup-2fa-ssh.sh` (via quickstart or directly), your server will be configured with:

1. **Google Authenticator (TOTP)** — 6-digit rotating code required on every login
2. **SSH Key authentication** — your public key must be present
3. **Password authentication disabled** — no password-only SSH access
4. **Fail2ban** — bans IPs after 3 failed attempts for 1 hour

**Your login flow after setup:**
```
ssh root@209.74.88.248
→ Verification code: [enter 6-digit TOTP from your app]
→ Logged in ✔
```

---

## Menu Options Explained

### Option 1 — Run Full 2FA Setup
Runs `setup-2fa-ssh.sh` interactively. Use on a **fresh server** or to re-apply the full configuration. Will prompt you to:
- Paste your SSH public key (if not already present)
- Scan the QR code with Google Authenticator or Authy
- Save scratch codes

> ⚠️ Keep an existing terminal session open before running this.

### Option 2 — Check Current SSH + 2FA Status
Audits your server's current state and shows:
- Whether sshd is running
- Active SSH config values
- PAM google-authenticator status
- Whether authorized_keys exists
- cPanel override file status

Use this to quickly verify everything is configured correctly.

### Option 3 — Emergency: Restore SSH Access
If you get locked out, use WHM Terminal or the Namecheap KVM Console to run this option. It will:
- Re-enable password authentication
- Comment out the google-authenticator PAM line
- Restart sshd

This gives you plain password SSH access back so you can troubleshoot and re-run setup.

### Option 4 — Check Fail2ban Status
Shows currently banned IPs, total failed attempts, and whether the SSH jail is active. Also offers to start fail2ban if it's not running.

### Option 5 — Re-generate Google Authenticator TOTP
Use this if you get a new phone, lose your authenticator app, or need to reset 2FA. Overwrites `/root/.google_authenticator` with a new secret and QR code.

> ⚠️ You must update your authenticator app immediately after running this.

### Option 6 — Deploy Toolkit to a New Server
Copies `quickstart.sh` and `setup-2fa-ssh.sh` to a new server via SCP. Prompts for the server IP, user, and destination path.

### Option 7 — Quick Reference
Prints key commands, file locations, login flow, and AlmaLinux 9/cPanel gotchas without leaving the terminal.

---

## AlmaLinux 9 + cPanel Gotchas

This server setup has several non-obvious issues that differ from standard Ubuntu/Debian guides:

| Problem | Why It Happens | Fix |
|---------|---------------|-----|
| `keyboard-interactive` gets disabled | `50-redhat.conf` sets `ChallengeResponseAuthentication no` | Override in `000-cpanel-options.conf` |
| SSHD fails to start after adding `AuthenticationMethods` | cPanel conf takes priority over `sshd_config` | Set `AuthenticationMethods` in `000-cpanel-options.conf` only |
| Two password prompts (TOTP + password) | PAM `password-auth` substack is active | Comment out `auth substack password-auth` in `/etc/pam.d/sshd` |
| Config changes don't take effect | cPanel drop-in files override `sshd_config` | Always edit `000-cpanel-options.conf` for auth settings |

---

## Key Files on the Server

```
/etc/pam.d/sshd                                  PAM authentication config
/etc/ssh/sshd_config                             Main SSH daemon config
/etc/ssh/sshd_config.d/000-cpanel-options.conf  cPanel overrides (edit this, not sshd_config)
/etc/ssh/sshd_config.d/50-redhat.conf           RHEL defaults (do not edit)
/root/.google_authenticator                      TOTP secret + scratch codes
/root/.ssh/authorized_keys                       Authorized SSH public keys
/etc/fail2ban/jail.local                         Fail2ban SSH jail config
```

---

## Useful Commands

```bash
# Check what SSH is actually running with
sshd -T | grep -E "passwordauth|kbdinteractive|usepam|authmethod"

# Validate config before restarting
sshd -t

# Restart SSH
systemctl restart sshd

# View SSH errors
journalctl -xeu sshd.service | tail -20

# Check fail2ban
fail2ban-client status sshd

# Unban an IP
fail2ban-client set sshd unbanip <ip-address>
```

---

## Backup Access Methods

If you get locked out of SSH, use these in order:

1. **Keep a session open** — always have an active SSH terminal when making changes
2. **WHM Terminal** — Namecheap panel → WHM → Terminal (web-based root access)
3. **Namecheap KVM Console** — VPS panel → Launch Console (direct VM access, SSH-independent)

Once in via backup access, run `bash quickstart.sh` and choose **Option 3**.

---

## Scratch Codes

When you ran `google-authenticator`, it generated 5 emergency scratch codes. These are one-time-use codes that bypass TOTP — your only recovery option if you lose your phone.

**Store them in:**
- A password manager (1Password, Bitwarden, etc.)
- Encrypted notes
- Printed and stored physically

---

## Server Info

| Field | Value |
|-------|-------|
| Hostname | server1.realtorstudio.io |
| IP | 209.74.88.248 |
| OS | AlmaLinux 9 cPanel (64-bit) |
| Host | Namecheap VPS |
| Auth | SSH Key + TOTP |

---

*Last updated: February 2026*

Developed and Designed by Alex Tannenbaum - Realtor Studio LLC 2026