# Archiver

A production-grade backup tool for Linux, cPanel, and DirectAdmin servers.
Pure Bash 4+ — no dependencies on `jq`, `python`, or `node`.

Supports **MySQL/MariaDB**, **SQLite**, and **file/directory** backups,
with optional upload to **Telegram** and **Discord**, AES-256 encryption,
retention policies, and cron scheduling.

---

## Installation

Run this single command to install or update Archiver:

```bash
curl -fsSL https://raw.githubusercontent.com/s7net/archiver/refs/heads/main/install.sh -o /tmp/archiver_install.sh && bash /tmp/archiver_install.sh && rm -f /tmp/archiver_install.sh
```

That's it. The installer will:
- Detect your privilege level (root → `/usr/local/bin`, otherwise → `~/bin`)
- Ask before overwriting an existing installation
- Add `~/bin` to your `PATH` automatically if needed
- Check all required and optional dependencies

> Works in jailed shell environments (cPanel, DirectAdmin) without root access.

### If `archiver` is not found after install

Add this to your `~/.bashrc` or `~/.profile` and reload:

```bash
export PATH="$HOME/bin:$PATH"
source ~/.bashrc
```

---

## Requirements

| Tool | Required | Purpose |
|------|----------|---------|
| `curl` | ✅ Yes | Uploading backups / downloading |
| `tar` | ✅ Yes | Creating archives |
| `gzip` | ✅ Yes | Compression |
| `openssl` | Optional | AES-256 encryption |
| `mysqldump` | Optional | MySQL / MariaDB backup |
| `mysql` | Optional | MySQL restore |
| `sqlite3` | Optional | SQLite backup & integrity check |
| `flock` | Optional | Concurrent run protection |
| `crontab` | Optional | Scheduled backups |

Run `archiver doctor` to check your environment.

---

## Quick Start

```bash
# Add a new backup profile (interactive wizard)
archiver add

# Run all backups
archiver run

# Run a specific profile
archiver run db_mysite

# Preview what would happen (no files created)
archiver run --dry-run

# Check environment health
archiver doctor

# View recent log output
archiver logs
```

---

## Commands

| Command | Description |
|---------|-------------|
| `archiver add` | Interactive wizard to add a new backup profile |
| `archiver edit [profile]` | Edit an existing profile |
| `archiver remove [profile]` | Delete a profile |
| `archiver list` | List all profiles |
| `archiver run [profile] [--dry-run]` | Run backups |
| `archiver restore` | Interactive restore wizard |
| `archiver cron install <schedule> [profile]` | Schedule with cron |
| `archiver cron remove [profile]` | Remove cron job |
| `archiver cron show` | List archiver cron entries |
| `archiver doctor [profile]` | Environment & connectivity checks |
| `archiver test` | Self-test (compression, encryption, uploads) |
| `archiver stats` | Backup statistics per profile |
| `archiver logs [n]` | Show last n log lines (default: 50) |
| `archiver find <term>` | Search backups by name or profile |
| `archiver export [file]` | Export all configs to a tar.gz |
| `archiver import <file>` | Import configs from a tar.gz |
| `archiver version` | Show version |
| `archiver help` | Show help |

---

## Backup Types

### MySQL / MariaDB
```bash
archiver add
# → Database → mysql/mariadb
# → enter host, port, user, password, database name
```

### SQLite
```bash
archiver add
# → Database → sqlite
# → enter path to .sqlite / .db file
```

### Directory or Single File
```bash
archiver add
# → Directory or Single File
# → enter source path
```

---

## Upload Destinations

### Telegram
- Create a bot via [@BotFather](https://t.me/BotFather)
- Get your Chat ID (and optionally a Topic/Thread ID for supergroups)
- Enter them during `archiver add`

Files larger than **45 MB** are automatically split into chunks.

### Discord
- Create a Webhook in your server's channel settings
- Paste the URL during `archiver add`

Files larger than **8 MB** are automatically split into chunks.

> If no upload destination is configured, backups are kept locally in `~/.archiver/backups/`.

---

## Encryption

When enabled, archives are encrypted with **AES-256-CBC** (via `openssl`) before upload.
The password is stored in the profile config (`~/.archiver/configs/`), which is readable only by your user (mode `600`).

To decrypt a backup manually:
```bash
openssl enc -aes-256-cbc -pbkdf2 -d -in backup.tar.gz.enc -out backup.tar.gz -pass pass:YOUR_PASSWORD
```

---

## Scheduling

```bash
# Daily at 3 AM (all profiles)
archiver cron install daily

# Every 6 hours (specific profile)
archiver cron install 6h db_mysite

# Custom cron expression
archiver cron install "0 */4 * * *" db_mysite

# Show scheduled jobs
archiver cron show

# Remove a job
archiver cron remove db_mysite
```

---

## Retention

During `archiver add`, set a **retention count** (e.g. `10`) to automatically delete older backups
after each run, keeping only the most recent N archives.

Set to `0` for unlimited retention.

---

## File Structure

```
~/.archiver/
├── configs/      # Backup profiles (.conf files, mode 600)
├── backups/      # Local backup archives
├── logs/         # archiver.log (rotated at 5 MB, keeps last 5)
├── metadata/     # Per-profile run statistics
├── tmp/          # Temporary working directory
└── restore/      # Restore workspace
```

---

## Restore

```bash
archiver restore
```

The interactive wizard lets you:
- Browse local backups
- Auto-detect and merge split chunks
- Decrypt encrypted archives
- Restore MySQL dumps, SQLite databases, or files/directories

---

## Exporting & Importing Configs

Useful for migrating to a new server:

```bash
# On the old server
archiver export ~/archiver-configs.tar.gz

# On the new server
archiver import ~/archiver-configs.tar.gz
```

> ⚠️ Exported files contain credentials. Keep them secure.

---

## Troubleshooting

```bash
# Full environment check
archiver doctor

# Check a specific profile
archiver doctor db_mysite

# Run the built-in self-test
archiver test

# Enable debug output
ARCHIVER_DEBUG=1 archiver run db_mysite
```

---

## License

MIT
