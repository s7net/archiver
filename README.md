# Archiver

<img width="1024" height="572" alt="image" src="https://github.com/user-attachments/assets/024dc7e4-9f7a-4331-8524-47db739a6861" />

A production-grade backup tool for Linux, cPanel, and DirectAdmin servers.
Pure Bash 4+ — no dependencies on `jq`, `python`, or `node`.

Supports **MySQL/MariaDB**, **PostgreSQL**, **SQLite**, and **file/directory** backups,
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
- Safely update existing installations without affecting configurations, archives, or schedules
- Automatically back up the previous binary (`archiver.bak`) before updating
- Add `~/bin` to your `PATH` automatically if needed
- Check all required and optional dependencies

> Works in jailed shell environments (cPanel, DirectAdmin) without root access.

### Updating Archiver

You can update Archiver at any time directly from the CLI or via a single curl command:

```bash
# Method 1: Built-in update command
archiver update

# Method 2: One-liner updater from GitHub
curl -fsSL https://raw.githubusercontent.com/s7net/archiver/refs/heads/main/install.sh | bash
```

> **Safe Update Guarantee:** Updating Archiver updates only the executable binary. All your existing backup profiles, credentials, archives, logs, and cron jobs in `~/.archiver` are strictly preserved and untouched. A backup of the previous binary is saved as `archiver.bak`.

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
| `pg_dump` | Optional | PostgreSQL backup |
| `psql` | Optional | PostgreSQL restore |
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
| `archiver retention [profile]` | Enforce retention policy and remove old backups |
| `archiver settings` | Interactive global settings, bots, and Topic Mode configuration |
| `archiver bot [list\|add\|remove\|default\|test]` | Manage Telegram bots and test connections |
| `archiver version` | Show version |
| `archiver update` | Update Archiver to latest version safely |
| `archiver update-check` | Check if a newer version is available |
| `archiver help` | Show help |

---

## Backup Types

### MySQL / MariaDB
```bash
archiver add
# → Database → mysql/mariadb
# → enter host, port, user, password, database name
```

### PostgreSQL
```bash
archiver add
# → Database → postgres
# → enter host, port (default 5432), user, password, database name
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
# → enter exclude patterns (optional, e.g. node_modules, .git, cache, *.log)
```

---

## Global Settings & Telegram Bots

You can register your Telegram bots once and reuse them across all backup profiles without having to re-enter tokens:

```bash
# Open interactive settings menu
archiver settings

# Or manage bots directly via CLI
archiver bot add main       # Add a bot with token and default chat/group
archiver bot list           # List configured bots
archiver bot default main   # Set default bot for all backups
archiver bot test main      # Test bot connection and topic creation
```

When creating backups with `archiver add`, Archiver automatically lets you pick from your saved bots with a single click.

---

## Telegram Topic Mode (Forum Supergroups)

Archiver features **Topic Mode** for Telegram Supergroups with Topics (Forum) enabled:

- **Automatic Forum Topic Creation**: When backups run, Archiver automatically calls Telegram's `createForumTopic` API to create a dedicated topic thread for each profile.
- **Smart Server Hostname Naming**: Topics are formatted as:
  ```
  <Capitalized-Hostname-Prefix> - <Profile-Name>
  ```
  *Examples:*
  - Hostname `srv1.company.com` + profile `db_site` $\rightarrow$ `Srv1 - db_site`
  - Hostname `node-db` + profile `files_app` $\rightarrow$ `Node-db - files_app`
- **Topic Caching & Re-use**: The created `message_thread_id` is cached and saved in the profile config. Subsequent backups and failure alerts for that profile are sent into the **same thread** rather than creating duplicate topics.
- **Requirements**:
  1. The group must be a Telegram **Supergroup** with **Topics** enabled.
  2. The bot must be an **Administrator** with the **"Manage Topics"** permission.
  3. Enter the numerical group ID (e.g. `-1001234567890`) when enabling Topic Mode in `archiver settings` or `archiver bot add`.

---

## Upload Destinations & Failure Alerts

### Telegram
- Create a bot via [@BotFather](https://t.me/BotFather)
- Configure it in `archiver settings` or enter the token directly during `archiver add`
- Files larger than **45 MB** are automatically split into chunks.

### Discord
- Create a Webhook in your server's channel settings
- Paste the URL during `archiver add`
- Files larger than **8 MB** are automatically split into chunks.

### Failure Alerts
If a backup fails (e.g. database down, disk space low, or upload error), Archiver immediately dispatches an alert with the server hostname, profile name, timestamp, and failure cause to your configured Telegram chat/topic or Discord webhook.

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
