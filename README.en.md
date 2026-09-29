<div align="center">

<a href="README.md"><img src="docs/button-ru.svg" alt="Русская версия: читать этот README на русском" width="420"></a>

<img src="docs/banner.en.svg" alt="PostgreSQL on a VPS: deploy and manage with a single script" width="100%">

<p>
<a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-2ea44f?style=flat-square"></a>
<img alt="PostgreSQL 17" src="https://img.shields.io/badge/PostgreSQL-17-336791?style=flat-square&logo=postgresql&logoColor=white">
<img alt="Ubuntu and Debian" src="https://img.shields.io/badge/Ubuntu%20%7C%20Debian-supported-E95420?style=flat-square&logo=ubuntu&logoColor=white">
<img alt="Bash" src="https://img.shields.io/badge/shell-bash-4EAA25?style=flat-square&logo=gnubash&logoColor=white">
<img alt="Idempotent setup" src="https://img.shields.io/badge/setup-idempotent-0ea5e9?style=flat-square">
<img alt="Languages: English and Russian" src="https://img.shields.io/badge/lang-RU%20%7C%20EN-8b5cf6?style=flat-square">
<a href="https://github.com/Poleno7682/postgres-vps-setup/stargazers"><img alt="Stars" src="https://img.shields.io/github/stars/Poleno7682/postgres-vps-setup?style=flat-square&logo=github"></a>
</p>

<p>
<a href="#quick-start"><img alt="Quick start" src="https://img.shields.io/badge/-Quick_start-2ea44f?style=for-the-badge&logo=gnubash&logoColor=white"></a>
<a href="#features"><img alt="Features" src="https://img.shields.io/badge/-Features-2563eb?style=for-the-badge&logo=postgresql&logoColor=white"></a>
<a href="#command-reference"><img alt="Commands" src="https://img.shields.io/badge/-Commands-7c3aed?style=for-the-badge&logo=windowsterminal&logoColor=white"></a>
<a href="#screenshots"><img alt="Screenshots" src="https://img.shields.io/badge/-Screenshots-ea580c?style=for-the-badge"></a>
<a href="#faq"><img alt="FAQ" src="https://img.shields.io/badge/-FAQ-db2777?style=for-the-badge&logo=readme&logoColor=white"></a>
<a href="README.md"><img alt="Русский" src="https://img.shields.io/badge/-%D0%A0%D1%83%D1%81%D1%81%D0%BA%D0%B8%D0%B9-475569?style=for-the-badge&logo=googletranslate&logoColor=white"></a>
</p>

<p><b>One script turns a fresh VPS into a PostgreSQL host for multiple projects:<br>every project gets its own database, users and permissions.</b></p>

</div>

`pg_server_setup.sh` turns a fresh **dedicated Ubuntu/Debian server into a PostgreSQL host for multiple projects**: every project gets its own database, its own users and permissions, and tables of different projects never overlap.

The script is **idempotent**: running it again checks what is already installed and running and configures only what is missing.

> [!NOTE]
> **Language:** the script speaks **English and Russian**. On the first interactive run it asks which language to use and remembers the choice; change it any time with `sudo ./pg_server_setup.sh lang [en|ru]` (or `LANG_UI=en|ru` for non-interactive runs). Without an interactive terminal the language is taken from the system `$LANG`.

<details>
<summary><b>Table of contents</b></summary>

- [Features](#features)
- [Requirements](#requirements)
- [Quick start](#quick-start) (including [one-command install](#one-command-install))
- [Terminal interface and screenshots](#terminal-interface)
- [What `setup` does](#what-setup-does)
- [Network modes](#network-modes)
- [PostgreSQL port](#postgresql-port) and [NAT](#nat-external-port-and-protocol)
- [Isolation model and roles](#isolation-model-and-roles)
- [Command reference](#command-reference)
- [Scenarios](#scenarios)
- [Connecting from an application](#connecting-from-an-application)
- [Auto-tuning to the server](#auto-tuning-to-the-server)
- [Backups and restore](#backups-and-restore)
- [Environment variables](#environment-variables)
- [What the script creates on the server](#what-the-script-creates-on-the-server)
- [Security checklist](#security-checklist)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [Updates](#updates) · [Removal](#removal)

</details>

---

## Features

<table>
<tr>
<td width="50%" valign="top"><b>🚀 Setup without surprises</b><br>PostgreSQL from the PGDG repository, autostart. Re-running verifies every step and <b>continues where it stopped</b>.</td>
<td width="50%" valign="top"><b>🧠 Auto-tuning for your server</b><br>Analyses cores, RAM and disk: <code>shared_buffers</code>, <code>work_mem</code>, <code>max_connections</code>, parallel workers, WAL.</td>
</tr>
<tr>
<td width="50%" valign="top"><b>🌐 Network your way</b><br><code>local</code>, <code>private</code> (VPN/VPC) or <code>public</code> (IP allowlist or everyone). Port: 5432, custom or a random free one.</td>
<td width="50%" valign="top"><b>📡 Servers behind NAT</b><br>The provider-assigned external port in the connection details and URL. Reminder: PostgreSQL works over TCP only.</td>
</tr>
<tr>
<td width="50%" valign="top"><b>🗄️ A database per project</b><br>A dedicated database and permissions per project; tables never overlap. Profiles: <code>owner</code>, <code>readwrite</code>, <code>readonly</code>.</td>
<td width="50%" valign="top"><b>🔑 Passwords and details</b><br>Your own password (Latin letters and digits, 6+ characters) or a generated one. A copy-paste block and a ready-to-use <b>connection URL</b>.</td>
</tr>
<tr>
<td width="50%" valign="top"><b>💾 Backups</b><br>Daily <code>pg_dump</code> of every database and roles, rotation, a final dump before a database is dropped.</td>
<td width="50%" valign="top"><b>🖥️ A beautiful terminal</b><br>Colourful interface: banner, boxes, progress, a separate clean screen for every menu item. English and Russian.</td>
</tr>
</table>

## Requirements

- A VPS running **Ubuntu 22.04 / 24.04** or **Debian 11 / 12 / 13** (`systemd` and `apt` are required).
- SSH access as **root** (or via `sudo`).
- Outbound internet access from the server (PGDG repository).
- Full virtualization (KVM etc.). The script will not work in containers without `systemd`.

Recommended configuration for several small and medium projects:

| Resource | Minimum | Comfortable |
|---|---|---|
| CPU | 1–2 cores | 2–4 cores |
| RAM | 2 GB | 4–8 GB |
| Disk | SSD | NVMe, keep 30% free |

> [!TIP]
> Example: a server with **2 cores / 4 GB RAM / 60 GB SSD / 100 Mbit/s** is a great dedicated database host for several projects.

## Quick start

### Before you install: update the system

> [!IMPORTANT]
> Before running the script it is recommended to update all packages on the server, especially on a freshly created VPS. That way PostgreSQL is installed on up-to-date libraries with security fixes, and `apt` does not clash with background updates.

1. Refresh the package index and upgrade all installed packages:

```bash
sudo apt-get update && sudo apt-get -y full-upgrade
```

2. Remove packages that are no longer needed (optional):

```bash
sudo apt-get -y autoremove
```

3. Check whether a reboot is required (it is after kernel and core library updates):

```bash
[ -f /var/run/reboot-required ] && echo "Reboot required" || echo "No reboot needed"
```

If it is required, reboot the server and reconnect over SSH:

```bash
sudo reboot
```

> [!TIP]
> On a freshly created VPS an automatic update (`cloud-init`, `unattended-upgrades`) often runs during the first minutes, and `apt` reports "Could not get lock". The script waits for the lock for up to 2 minutes on its own, but it is better to let the update finish before starting the installation.

### One-command install

Connect to the server over SSH and run (as root or with `sudo`):

```bash
curl -fsSL https://raw.githubusercontent.com/Poleno7682/postgres-vps-setup/main/pg_server_setup.sh -o pg_server_setup.sh && chmod +x pg_server_setup.sh && sudo ./pg_server_setup.sh setup
```

The command downloads the script, makes it executable, and immediately starts the initial setup. The script stays in the current directory and is later used to manage databases and users (`sudo ./pg_server_setup.sh` opens the menu).

If `curl` is missing, install it (`apt-get update && apt-get install -y curl`) or use `wget`:

```bash
wget -qO pg_server_setup.sh https://raw.githubusercontent.com/Poleno7682/postgres-vps-setup/main/pg_server_setup.sh && chmod +x pg_server_setup.sh && sudo ./pg_server_setup.sh setup
```

Or with `git`:

```bash
git clone https://github.com/Poleno7682/postgres-vps-setup.git && cd postgres-vps-setup && sudo ./pg_server_setup.sh setup
```

> [!NOTE]
> Do not run the script as `curl ... | bash`: in interactive mode it asks questions (network mode, port, password) and needs keyboard input. That is why the file is downloaded first and then executed.
>
> Before running anything from the internet as root, read it: `less pg_server_setup.sh`. For reproducibility you can pin a specific commit by putting its hash in the URL instead of `main`.

Non-interactive variant (no prompts, parameters passed through environment variables):

```bash
curl -fsSL https://raw.githubusercontent.com/Poleno7682/postgres-vps-setup/main/pg_server_setup.sh -o pg_server_setup.sh && chmod +x pg_server_setup.sh \
  && sudo NETWORK_MODE=public ACCESS_POLICY=list ALLOWED_CIDR="203.0.113.10" DB_PORT=random ./pg_server_setup.sh -y setup
```

### Manual install

#### 1. Copy the script to the server

```bash
scp pg_server_setup.sh root@<SERVER_IP>:/root/
ssh root@<SERVER_IP>
chmod +x /root/pg_server_setup.sh
```

If you get an error mentioning `\r` or `bad interpreter`, the file was saved with Windows line endings:

```bash
sed -i 's/\r$//' /root/pg_server_setup.sh
```

#### 2. Run the initial setup

```bash
sudo ./pg_server_setup.sh setup
```

Step by step, the script will:

0. on the very first interactive run, ask for the message language (English / Русский);
1. show a server analysis (cores, RAM, disk);
2. install PostgreSQL (if not installed yet);
3. ask for the **network mode** (`local` / `private` / `public`) and the IPs allowed to connect;
4. ask for the PostgreSQL **port** (standard 5432, custom, or a random free one) and whether the server is **behind NAT** with port forwarding (external port);
5. tune PostgreSQL for your hardware and restart the service;
6. configure swap and backups, and offer to enable the `ufw` firewall;
7. offer to create the first database and its owner right away and print the connection details (IP, port, database, login, password);
8. after you press `Enter`, **open the management menu automatically**.

#### 3. Create databases and users

```bash
# database + owner (a password is generated, or set your own)
sudo ./pg_server_setup.sh db-create myproject_db myproject_owner

# application user with read/write access
sudo ./pg_server_setup.sh user-create myproject_app myproject_db readwrite

# read-only user (reports, BI)
sudo ./pg_server_setup.sh user-create myproject_report myproject_db readonly
```

At the end of each command a connection details block is printed:

```text
==================== Connection details ====================
  IP:           203.0.113.9
  Port:         5432
  Protocol:     TCP
  Database:     myproject_db
  Login:        myproject_owner
  Password:     ********************
  SSL:          sslmode=require
```

The password is shown **only once**, at this final stage (after `setup` if you created the first database, and after `db-create`, `user-create` and `user-passwd`). It is never printed again: `status`, `list` and the menu do not show it. Save it to a password manager or your application's secrets immediately.

Below the box the same data is printed again as **plain text without decoration**, ready to copy and paste, followed by a ready-to-use **connection URL** for project configuration (the password is URL-encoded, so special characters do not break it):

```text
Copy-paste details:
IP: 203.0.113.9
Port: 25762
Protocol: TCP
Database: myproject_db
Login: myproject_owner
Password: 3f9a1c7e5b2d80461a9e0c7d4b5f2e83
SSL: sslmode=require

Connection URL (for project configuration):
postgresql://myproject_owner:3f9a1c7e5b2d80461a9e0c7d4b5f2e83@203.0.113.9:25762/myproject_db?sslmode=require
```

**How the IP is determined.** First the address PostgreSQL listens on. If it listens on `*` (all interfaces), the address of the interface or default route is used. If the server is behind NAT and no public IP is configured on any interface, the script asks the `api.ipify.org` service once for the external address (only in `public` mode and only in that situation; the result is cached). If detection fails, `setup` asks for the IP or domain and saves it. You can set the address manually with `PGMGR_HOST` (for example, a domain name).

#### 4. Interactive menu

Running without arguments opens a menu with all actions:

```bash
sudo ./pg_server_setup.sh
```

## Terminal interface

- **A separate screen for every item.** Before each action the console is cleared and a banner plus a section title is drawn, so earlier output never gets in the way. After the action the script waits for `Enter` and returns to the menu (so a password stays on screen until you have saved it).
- **The main menu** is grouped (Server, Databases and users, Other) and shows live status: PostgreSQL version and state, port, network mode, database count. Managing databases and users lives in one **"Databases"** section built as navigation: **database list → a database → a user**.
  - The database list shows the owner, size and number of users; it also has "Create a new database".
  - A database screen lets you **create a new user**, **select an existing one**, **delete a user** (revoke access to this database or delete completely), rename the database, change its owner or drop it.
  - Selecting a user shows the **connection details without the password** (IP, port, protocol, database, login, permissions, IP access), a copy-paste block and a URL to fill the password into, plus actions: **change the password**, change the profile, add or remove IP access, connection limit, rename and delete the user.
  - Separate items such as "Create database", "Change password" or "Delete user" were removed from the main menu: they now live inside the matching screens. The same commands (`db-create`, `user-passwd`, …) stay available for scripts.
- **"Server status"** is a live dashboard: gauges and mini graphs (sparklines) over the last seconds for **CPU, load average, RAM, swap, disk and network**, and for PostgreSQL: **connections, transactions per second, cache hit ratio, uptime**. It refreshes every 2 seconds and exits on any key. Gauge colours show the load level (green, yellow, red). The `g` key switches the mini-graph style: `· ░ ▒ ▓ █` by default (present in every font, including PuTTY with Courier New) or the smooth `▁▂▃▄▅▆▇█`, which needs a font with the full block-element range. The choice is remembered.
- **Back with `0`.** Every choice question (network mode, port, NAT, how to set a password, language and others) has a `0  Back` item. It cancels the current action and returns to the previous menu without an extra pause. Typing `0` in text questions (database name, IP, port, etc.) and at the password prompt does the same. Exception: in the connection-limit question `0` is an ordinary value (a user who may not connect).
- **`setup`** shows `[3/8]` steps with a progress bar; package installation runs with a spinner and the verbose `apt` output is shown only on failure.
- **Boxes and colours:** green — success, yellow — warnings and confirmations, red — errors, cyan — questions.
- **Automatic plain fallback:** when output is not a terminal (logs, `ssh host cmd | tee`, cron) or `NO_COLOR=1` is set, colours, screen clearing and animation are disabled. With `-y` the screen is never cleared. Terminals without UTF-8 get ASCII boxes and icons.

### Screenshots

The images are generated from the script's real UI code with sample data (`tools/render_screens.sh`); no server is needed to produce them.

<table>
<tr><td width="50%" align="center" valign="top"><b>Main menu</b><br><br><img src="docs/screenshots/menu.en.svg" alt="Main menu" width="100%"></td><td width="50%" align="center" valign="top"><b>Server status: live load graphs</b><br><br><img src="docs/screenshots/status.en.svg" alt="Server status: live load graphs" width="100%"></td></tr>
<tr><td width="50%" align="center" valign="top"><b>Databases</b><br><br><img src="docs/screenshots/databases.en.svg" alt="Databases" width="100%"></td><td width="50%" align="center" valign="top"><b>One database: users and actions</b><br><br><img src="docs/screenshots/database.en.svg" alt="One database: users and actions" width="100%"></td></tr>
<tr><td width="50%" align="center" valign="top"><b>User: connection details without the password</b><br><br><img src="docs/screenshots/user.en.svg" alt="User: connection details without the password" width="100%"></td><td width="50%" align="center" valign="top"><b>Initial setup</b><br><br><img src="docs/screenshots/setup.en.svg" alt="Initial setup" width="100%"></td></tr>
<tr><td width="50%" align="center" valign="top"><b>Resuming after an interruption</b><br><br><img src="docs/screenshots/resume.en.svg" alt="Resuming after an interruption" width="100%"></td><td width="50%" align="center" valign="top"><b>Summary: network and "Done"</b><br><br><img src="docs/screenshots/network.en.svg" alt="Summary: network and "Done"" width="100%"></td></tr>
<tr><td colspan="2" align="center" valign="top"><b>Connection details (the password is shown once; the one in the screenshot is a placeholder)</b><br><br><img src="docs/screenshots/creds.en.svg" alt="Connection details (the password is shown once; the one in the screenshot is a placeholder)" width="60%"></td></tr>
</table>

## What `setup` does

| Step | On re-run |
|---|---|
| Server analysis | Always prints a fresh report |
| PostgreSQL installation (PGDG) | Skipped if a cluster already exists |
| Service check and start | Starts the service if it is stopped |
| Network mode selection | Uses the saved one (`/etc/pgmgr/pgmgr.conf`), does not ask again |
| Port selection | Uses the saved one, does not ask again; on change restarts PostgreSQL and migrates `ufw` rules |
| Settings file `99-pgmgr.conf` | Rewritten only if it changed; a restart happens only then |
| Revoke PUBLIC access to the `postgres` maintenance DB, `pg_stat_statements` | Idempotent |
| 2 GB swap and `vm.swappiness=1` | Created only if there is no swap yet |
| Daily backup (cron, 03:00) | The script and cron file are regenerated |
| `ufw` firewall | Offered if inactive; rules for the selected networks are added |

Change the network mode later with `sudo ./pg_server_setup.sh network`.

### If setup was interrupted

A dropped SSH session, `Ctrl+C`, a reboot or an error in the middle of `setup` is not a problem: **just run `sudo ./pg_server_setup.sh setup` again**.

- The script remembers that the previous run did not finish and shows a "Resuming setup" box with the step where it stopped. It does not rely on that memory alone: **every step is verified against the real state of the system**.
- Completed work is skipped (marked with `↷` in the output): installed packages (prerequisites, `postgresql-<version>`), the configured PGDG repository, the created cluster, enabled autostart, the running service, an up-to-date settings file, active swap, `vm.swappiness`, the generated backup script and schedule, installed `ufw`.
- Missing pieces are completed: an interrupted package installation (`dpkg --configure -a`), a package without a cluster (the cluster is created), an inactive `/swapfile` (activated), settings that were written but not applied because the restart was interrupted (the service is restarted).
- The chosen language, network mode and port are saved immediately, so they are not asked again.

Tip: on an unstable connection run `setup` inside `tmux` or `screen`, so a dropped SSH session does not stop the installation.

## Network modes

The mode is chosen on the first `setup` (interactively or via environment variables) and saved to `/etc/pgmgr/pgmgr.conf`.

### `local`: this server only

- `listen_addresses = 'localhost'`.
- The port is not reachable from outside. Suitable when the application runs on the same VPS.
- Connect with `host=127.0.0.1`.

### `private`: private network or VPN

- PostgreSQL listens on `localhost` and the selected private IP (`10.x`, `172.16–31.x`, `192.168.x`, `100.64.x`).
- Suitable for WireGuard, Tailscale, or your hosting provider's private network (VPC).
- The script finds the server's private addresses itself, lets you pick one, and by default allows the subnet of the selected interface. The client list can be edited (comma-separated).
- The port is never opened to the internet.

### `public`: public IP

- Listens on the selected public IP (or `*` if the server is behind NAT or has several addresses).
- Two access policies:

| Policy | What happens |
|---|---|
| **list** (recommended) | Access only from the listed IPs / ranges, for example `203.0.113.10, 198.51.100.0/24` |
| **all** | Access from any address (`0.0.0.0/0`). You must type the word `EVERYONE` to confirm (`ВСЕМ` in Russian mode). Protected only by password and SSL |

- In public mode `log_connections` and `log_disconnections` are additionally enabled.
- Enabling `ufw` (`firewall-init`) is strongly recommended.

> [!NOTE]
> Even with the `all` policy, `pg_hba.conf` rules are created **for a specific "database + user" pair**, not "everyone to everything". Authentication is `scram-sha-256`, and the connection type is `hostssl` (SSL only).

## PostgreSQL port

After the network is selected, the script asks which port to use:

| Option | What happens |
|---|---|
| **Standard** | `5432` |
| **Custom** | You enter a port (1024–65535). The script checks that it is free and differs from the SSH port |
| **Random free** | The script picks a port from 10000–32000 that nothing is currently listening on |

The port is written to the cluster's `postgresql.conf` (via `pg_conftool`), the choice is saved in `/etc/pgmgr/pgmgr.conf`, and later `setup` runs do not ask again.

Change the port later:

```bash
sudo ./pg_server_setup.sh port            # interactive
sudo ./pg_server_setup.sh port 5433       # custom
sudo ./pg_server_setup.sh port random     # random free
sudo ./pg_server_setup.sh port default    # back to 5432
```

When the port changes, the script:

1. restarts PostgreSQL (active connections are dropped, confirmation is requested);
2. verifies that the server really listens on the new port;
3. migrates `ufw` rules: closes the old port and opens the new one for the same networks;
4. updates the backup script;
5. reminds you to update the connection strings of your applications.

For all new connections use `psql -p <port> ...` and `host:port` in URLs. `pg_hba.conf` rules do not depend on the port.

> [!NOTE]
> A non-standard port is not protection against attacks: scanners will find any open port. It only reduces log noise. The real protection is the network mode, IP allowlist, `ufw`, passwords and SSL.

## NAT, external port and protocol

If the server is behind NAT and the provider forwards a port, **you often cannot choose the external port** (the provider assigns it), but you can read it in the panel. After the port question the script asks: **is the server behind NAT with port forwarding?** If yes, enter the **external port** (as shown in the provider's panel).

The external port is used **for display only**: it appears in the "Connection details", in the copy-paste block and in the connection URL (`...@IP:external_port/...`). `ufw` and `pg_hba.conf` work with PostgreSQL's internal port, because NAT forwards the traffic to it.

Change the external port later (for example, when the provider assigns a new one): `sudo ./pg_server_setup.sh nat 37412`, or `nat none` to turn it off.

**TCP or UDP.** PostgreSQL works **over TCP only** (the protocol does not support UDP), so the connection details always show `Protocol: TCP` and the status checks that the port really listens over TCP. So create a forward of type **TCP** in the provider's panel: PostgreSQL will not work through a **UDP-only** forward (if UDP is all the provider offers, use a WireGuard/Tailscale tunnel — it runs over UDP — in the `private` mode). The script reminds you of this when you enter the external port.

## Isolation model and roles

**One PostgreSQL cluster, one database per project.** A user of project A cannot see or read the database of project B: `CONNECT` and the `public` schema privileges are revoked from `PUBLIC`, and access is granted only explicitly.

For every database `<db>` the script creates:

| Role | Type | Purpose |
|---|---|---|
| `<db>_owner` (or the name you give) | LOGIN | Database owner: DDL, migrations, creating tables |
| `<db>_rw` | NOLOGIN (group) | `SELECT`, `INSERT`, `UPDATE`, `DELETE` + `USAGE`/`SELECT`/`UPDATE` on sequences |
| `<db>_ro` | NOLOGIN (group) | `SELECT` only |

**A user's profile on a database = membership in a group:**

| Profile | What the user gets |
|---|---|
| `owner` | Becomes the database owner (full rights, DDL) |
| `readwrite` | Membership in `<db>_rw` |
| `readonly` | Membership in `<db>_ro` |
| `none` | Access to the database is revoked |

One user can have different profiles in different databases.

`readwrite` and `readonly` privileges automatically extend to **future tables** (via `DEFAULT PRIVILEGES`), but only for tables created by the **database owner**. Therefore:

> [!IMPORTANT]
> **Run migrations as the database owner** (`<db>_owner`) and connect the application as a user with the `readwrite` profile.

Limitations:

- Privileges are configured for the `public` schema. If a project needs its own schemas, grant rights on them separately.
- Database and user names: `a-z`, `0-9`, `_`, starting with a letter or `_`; databases up to 60 characters, users up to 63.
- Names ending in `_rw` and `_ro` are reserved for groups. Do not name regular users that way.

## Command reference

```bash
sudo ./pg_server_setup.sh [-y] <command> [arguments]
```

Arguments you do not pass are requested interactively. The `-y` flag disables confirmations (for automation).

| Command | Description |
|---|---|
| `setup [--recheck]` | Analysis, install, network mode, tuning, swap, backups (idempotent). Opens the menu when finished; on an **already configured** server it opens the menu right away, and `--recheck` forces the full check |
| `analyze` | Report on cores, RAM, disk |
| `network` | Change the network mode (`local` / `private` / `public`) |
| `port [N\|default\|random]` | Change the PostgreSQL port: 5432, custom, or random free |
| `nat [external_port\|none]` | Server behind NAT: set the external port shown to clients |
| `lang [en\|ru]` | Set the language of the script's messages |
| `status` | Service, resources, network, last backup |
| `list` | Databases, users, profiles, access rules |
| `db-create [db] [owner] [ip]` | Create a database, its owner and the `_rw` / `_ro` groups |
| `db-drop [db]` | Drop a database (a final dump is taken first) |
| `db-rename [old] [new]` | Rename a database (groups and `pg_hba` rules are updated) |
| `db-chown [db] [user]` | Transfer database ownership to another user |
| `user-create [user] [db] [profile] [ip]` | Create a user with a profile on a database |
| `user-role [user] [db] [profile]` | Change the profile (`owner` / `readwrite` / `readonly` / `none`) |
| `user-passwd [user]` | Change a password (your own or generated) |
| `user-limit [user] [N]` | Concurrent connection limit (`-1`: unlimited) |
| `user-rename [old] [new]` | Rename a user |
| `user-drop [user]` | Drop a user |
| `access-add [db] [user] [ip,cidr,...]` | Allow remote access (`pg_hba` + `ufw`) |
| `access-del [db\|*] [user\|*]` | Remove access rules |
| `backup-now` | Run a backup right now |
| `firewall-init` | Enable `ufw` (rate-limited SSH + deny incoming) |
| `menu` | Interactive menu (default) |

### Passwords

When creating a user, a database (its owner), and in `user-passwd`, the script asks you to:

1. **Generate** a strong random password (recommended);
2. **Enter your own**: hidden input with a confirmation prompt. The password is validated: **only Latin letters (upper and lower case) and digits**, no special characters, spaces or non-Latin letters, **at least 6 characters**. If it does not comply, the script explains why and asks again. Generated passwords always comply (40 characters, digits and Latin letters). The longer the password the better: for an internet-facing server prefer a generated one.

The final password (generated or entered by you) is shown once in the connection details block. Without an interactive terminal, pass a password through `PGMGR_PASSWORD` (not as a command-line argument: it would be visible in `ps`); if the variable is not set, a password is generated.

### Safe deletion

- `db-drop` and `user-drop` require typing the full object name (or `-y`).
- Before a database is dropped a final dump is taken: `/var/backups/postgresql/<db>_final_<date>.dump`.
- A user who owns a database cannot be dropped: use `db-chown` or `db-drop` first.

## Scenarios

### A. Application on the same server (`local`)

```bash
sudo NETWORK_MODE=local ./pg_server_setup.sh -y setup
sudo ./pg_server_setup.sh db-create app_db app_owner
sudo ./pg_server_setup.sh user-create app_user app_db readwrite
```

DSN: `postgresql://app_user:<password>@127.0.0.1:5432/app_db`

### B. Application on another server over a private network / VPN (`private`)

```bash
sudo ./pg_server_setup.sh setup          # choose the private mode and a private IP
sudo ./pg_server_setup.sh db-create app_db app_owner 10.0.0.0/24
sudo ./pg_server_setup.sh user-create app_user app_db readwrite 10.0.0.0/24
```

DSN: `postgresql://app_user:<password>@10.0.0.5:5432/app_db?sslmode=require`

### C. Public IP, access only from specific addresses (`public` + `list`)

Non-interactive:

```bash
sudo NETWORK_MODE=public ACCESS_POLICY=list \
     ALLOWED_CIDR="203.0.113.10,198.51.100.0/24" \
     ./pg_server_setup.sh -y setup
```

Later, add another address for a specific "database + user" pair:

```bash
sudo ./pg_server_setup.sh access-add app_db app_user 192.0.2.44
```

### D. Public IP, open to everyone (`public` + `all`)

```bash
sudo NETWORK_MODE=public ACCESS_POLICY=all ./pg_server_setup.sh setup
```

The script warns you and requires typing `EVERYONE` (`ВСЕМ` in Russian mode). Recommendations: strong passwords, `ufw`, a real SSL certificate, log monitoring.

### E. Permissions by role

```bash
sudo ./pg_server_setup.sh user-create analyst app_db readonly
sudo ./pg_server_setup.sh user-role analyst app_db readwrite   # promote
sudo ./pg_server_setup.sh user-role analyst app_db none        # revoke
sudo ./pg_server_setup.sh db-chown app_db new_owner            # transfer ownership
```

## Connecting from an application

Network connections use `hostssl`, so the client must use SSL:

```text
postgresql://USER:PASSWORD@HOST:5432/DBNAME?sslmode=require
```

Examples:

```python
# SQLAlchemy + psycopg2
engine = create_engine(
    "postgresql+psycopg2://app_user:PASSWORD@10.0.0.5:5432/app_db?sslmode=require",
    pool_size=5, max_overflow=5, pool_pre_ping=True,
)
```

```bash
# check from a client machine
psql "host=10.0.0.5 port=5432 dbname=app_db user=app_user sslmode=require"
```

If the password contains special characters (`@ : / ? # %`), they must be percent-encoded in the URL, for example with `urllib.parse.quote_plus`.

> [!NOTE]
> The default certificate is self-signed: it encrypts traffic but does not prove the server's identity. For `sslmode=verify-full`, install a real certificate (for example, Let's Encrypt).

When there are many clients (bots, workers, web), use connection pooling in the application and, if needed, PgBouncer in `transaction` mode.

## Auto-tuning to the server

`setup` (and `network`) calculate the configuration from the analysis results:

| Parameter | Formula |
|---|---|
| `shared_buffers` | 25% of RAM |
| `effective_cache_size` | 75% of RAM |
| `maintenance_work_mem` | RAM / 16 (at most 1 GB) |
| `work_mem` | (RAM − shared_buffers) / (max_connections × 3), clamped to 4–64 MB |
| `max_connections` | by RAM (~1 per 40 MB), at most `cores × 50`, clamped to 50–300 |
| `max_worker_processes` | at least 8, or the number of cores |
| `max_parallel_workers` | number of cores |
| `max_parallel_workers_per_gather` / `_maintenance_` | cores / 2, clamped to 1–4 |
| `autovacuum_max_workers` | 3 (4 with 4+ cores) |
| `random_page_cost`, `effective_io_concurrency` | SSD: `1.1` and `200`; HDD: `4.0` and `2` |
| `max_wal_size` | 2 GB (4 GB with 8+ GB RAM) |

Example for 2 cores / 3.9 GB RAM: `shared_buffers=975MB`, `effective_cache_size=2925MB`, `work_mem=9MB`, `max_connections=100`.

- **Server role.** If the server is dedicated to PostgreSQL (`dedicated`), all RAM is used in the calculation. If other services run on it (`shared`), half of it is used. The choice is saved and does not change on re-runs.
- **Disk type.** Virtual VPS disks are often misreported as HDD, so HDD is selected only on physical servers. Force it with `STORAGE=ssd|hdd`.
- Manual edits to `99-pgmgr.conf` are overwritten on the next `setup`. Put your own parameters in a separate file in `conf.d/` (with a name that sorts later).

## Backups and restore

Every day at **03:00** cron runs `/usr/local/sbin/pgmgr-backup` as `postgres`. Each database is dumped with `pg_dump -Fc`, and global roles are saved separately (`pg_dumpall --globals-only`). Files older than `BACKUP_RETENTION_DAYS` (14 by default) are deleted.

```text
/var/backups/postgresql/
├── app_db_2026-09-29_0300.dump
├── globals_2026-09-29_0300.sql
├── app_db_final_2026-09-29_1200.dump    # final dump made by db-drop
└── backup.log
```

Run a backup manually: `sudo ./pg_server_setup.sh backup-now`.

> [!WARNING]
> **Backups live on the same disk as the data.** Set up off-server copying (for example, `rclone` to S3/Backblaze/another server) and test restores periodically.

### Restoring a database

```bash
# 1. Create an empty database with its owner and groups
sudo ./pg_server_setup.sh db-create app_db app_owner

# 2. Load the dump (without importing owners from the dump)
sudo -u postgres pg_restore -d app_db --no-owner --role=app_owner \
     /var/backups/postgresql/app_db_2026-09-29_0300.dump
```

Roles and user passwords (when moving to a new server) are restored from `globals_*.sql`:

```bash
sudo -u postgres psql -f /var/backups/postgresql/globals_2026-09-29_0300.sql
```

## Environment variables

Mainly for non-interactive runs. The `-y` flag confirms all prompts.

| Variable | Value | Default |
|---|---|---|
| `NO_COLOR` | any value disables colours | unset |
| `LANG_UI` | `en` / `ru` (message language) | saved choice; first run asks; without a TTY: from system `$LANG` |
| `NETWORK_MODE` | `local` / `private` / `public` | interactive choice; without a TTY: `local` |
| `ACCESS_POLICY` | `list` / `all` (for `public`) | interactive choice |
| `LISTEN_ADDR` | comma-separated IPs or `*` | auto-selected from detected addresses |
| `ALLOWED_CIDR` | comma-separated client IPs/CIDRs | interface subnet (for `private`) |
| `DB_PORT` | `default` (5432) / `random` / a number 1024–65535 | interactive choice; without a TTY: current port |
| `EXTERNAL_PORT` | external NAT port (number 1–65535) or `none` | interactive question; without a TTY: saved value |
| `SERVER_ROLE` | `dedicated` / `shared` | `dedicated` |
| `PG_VERSION` | PostgreSQL major version | `17` |
| `MAX_CONNECTIONS` | number | auto-calculated |
| `STORAGE` | `ssd` / `hdd` | auto-detected |
| `SWAP_GB` | swap file size, GB (`0`: do not create) | `2` |
| `BACKUP_DIR` | backup directory | `/var/backups/postgresql` |
| `BACKUP_RETENTION_DAYS` | dump retention, days | `14` |
| `PGMGR_PASSWORD` | ready-made password (Latin letters and digits, at least 6 characters) | generated |
| `PGMGR_HOST` | IP or domain shown in the connection block and URL | auto-detected |
| `PGMGR_ASCII` | `1`: ASCII boxes and icons instead of Unicode | unset |
| `PGMGR_SPARK` | mini-graph style in the status view: `safe` / `fine` / `ascii` | `safe` (remembered via the `g` key) |

## What the script creates on the server

| Path | Purpose |
|---|---|
| `/etc/postgresql/<version>/main/conf.d/99-pgmgr.conf` | Server-specific settings (managed by the script) |
| `/etc/pgmgr/pgmgr.conf` | Saved language, network mode, policy, clients, port, server role |
| `/etc/postgresql/<version>/main/pg_hba.conf` | Access rules; the script's lines are tagged `# pgmgr:<db>:<user>` |
| `/etc/postgresql/<version>/main/pg_hba.conf.pgmgr.orig` | Copy of the original before the first edit |
| `/usr/local/sbin/pgmgr-backup`, `/etc/cron.d/pgmgr-backup` | Backup script and schedule |
| `/var/backups/postgresql/` | Dumps and backup log |
| `/etc/sysctl.d/99-pgmgr.conf` | `vm.swappiness = 1` |
| `/swapfile` (+ a line in `/etc/fstab`) | Swap, if there was none |

## Security checklist

- [ ] The network mode is the minimum necessary (`local` → `private` → `public`).
- [ ] In `public` an IP allowlist (`list`) is used, not `all`.
- [ ] `ufw` is enabled (`firewall-init`) and the PostgreSQL port is open only to the required addresses.
- [ ] Every project has its own databases and users; the application connects as a `readwrite` user, not as the owner.
- [ ] Migrations run as the database owner, reports as a `readonly` user.
- [ ] Passwords are long and unique and stored in secrets, not in git.
- [ ] SSH is key-only (`PasswordAuthentication no`) and `fail2ban` is installed.
- [ ] Automatic security updates are on (`unattended-upgrades`).
- [ ] Backups are copied off the server and restores are tested.
- [ ] For public mode a real SSL certificate is installed and clients use `sslmode=verify-full`.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `connection refused` / timeout | `local` mode, wrong port (check `status`), or the port is closed in `ufw` / at the hosting provider. Check `./pg_server_setup.sh status`, `ss -tlnp \| grep 5432`, `ufw status` |
| `no pg_hba.conf entry for host ..., SSL off` | The client connects without SSL: add `?sslmode=require` |
| `no pg_hba.conf entry for host ...` | No rule for this IP/database/user: `access-add <db> <user> <ip>` |
| `password authentication failed` | Wrong password or name: `user-passwd <user>` |
| `permission denied for table ...` | The tables were created by someone other than the database owner, or no profile was granted. Run migrations as the owner, check the profile in `list`, recreate the tables as the owner if needed |
| `permission denied for database` | The user has no profile on the database: `user-role <user> <db> readwrite` |
| Squares instead of graphs (PuTTY, old terminals) | The font lacks the character. The safe style `· ░ ▒ ▓ █` is the default (`g` in the status view switches style, `PGMGR_SPARK=safe`). For smooth graphs in PuTTY: pick a font with block characters in *Window → Appearance → Font* (DejaVu Sans Mono, Cascadia Mono, JetBrains Mono) and enable UTF-8 in *Window → Translation*. For pure ASCII: `PGMGR_ASCII=1` |
| Script: `bad interpreter` / `\r` | Windows line endings: `sed -i 's/\r$//' pg_server_setup.sh` |
| Swap was not created | Container virtualization does not allow swap: the warning can be ignored |
| Service does not start after `setup` | `journalctl -u postgresql@<version>-main -n 50`; most often an error in third-party edits of `conf.d` |
| Out of memory / PG restarts | Lower `max_connections`, add PgBouncer, add RAM. Check `SERVER_ROLE` (use `shared` on a shared server) |

Diagnostics:

```bash
sudo ./pg_server_setup.sh status
sudo ./pg_server_setup.sh list
sudo -u postgres psql -c "SELECT * FROM pg_hba_file_rules WHERE error IS NOT NULL;"
sudo tail -n 50 /var/log/postgresql/postgresql-*-main.log
```

## FAQ

<details>
<summary><b>Which systems are supported?</b></summary>

Ubuntu 22.04 / 24.04 and Debian 11 / 12 / 13 with `systemd` and `apt`. CentOS/RHEL, Alpine and containers without `systemd` are not supported.

</details>

<details>
<summary><b>Can I run `setup` again? Will anything break?</b></summary>

Yes. The script is idempotent: it checks the real state (packages, repository, cluster, service, settings file, swap, backup) and does only what is missing. Databases, users and data are untouched. Performance settings are recalculated for the current hardware, so re-running `setup` is useful after adding RAM. Note: on an already configured server an interactive `setup` **opens the management menu right away**; for a full check run `sudo ./pg_server_setup.sh setup --recheck` (or pick the first menu item). Running with `-y` or without a terminal always performs the full check.

</details>

<details>
<summary><b>Setup was interrupted (dropped SSH, `Ctrl+C`, reboot). What now?</b></summary>

Just run `sudo ./pg_server_setup.sh setup` again: the script shows the step where the previous run stopped, skips what is done and continues. Details: [“If setup was interrupted”](#if-setup-was-interrupted). On an unstable connection run `setup` inside `tmux` or `screen`.

</details>

<details>
<summary><b>I did not save the password. How can I see it?</b></summary>

You cannot: PostgreSQL stores only a password hash and the script never writes passwords to disk. Set a new one: `sudo ./pg_server_setup.sh user-passwd NAME` (in the menu: "Databases" → database → user → "Change the password"). The other details (IP, port, database, login) are always visible in `status` and `list`.

</details>

<details>
<summary><b>How do I connect my application?</b></summary>

Use the ready-made URL from the "Connection details" block: `postgresql://login:password@IP:port/database?sslmode=require`. For SQLAlchemy add the driver: `postgresql+psycopg2://…`. Examples: [“Connecting from an application”](#connecting-from-an-application).

</details>

<details>
<summary><b>Why a separate database owner and a `readwrite` user?</b></summary>

Least privilege. The owner creates and changes tables (migrations), while the application runs as a `readwrite` user that cannot drop tables or change the schema. Connect reports and BI with a `readonly` user. Privileges on new tables are granted automatically when the database owner creates them.

</details>

<details>
<summary><b>Can I keep several projects on one server?</b></summary>

Yes, that is the main purpose of the script. Every project gets its own database, and `CONNECT` plus schema rights are revoked from `PUBLIC`, so a user of one project cannot see or read another project's database.

</details>

<details>
<summary><b>How do I change the port, network mode or external port later?</b></summary>

`sudo ./pg_server_setup.sh port` (port), `network` (mode and IP list), `nat` (external port). `ufw` rules and the backup script are updated automatically when the port changes.

</details>

<details>
<summary><b>My server is behind NAT and the provider assigns the external port. How do I handle that?</b></summary>

Configure the internal port as usual and enter the external one in the NAT question (or `nat 37412`). It will appear in the connection details and the URL. Clients must connect to the external port; `ufw` and `pg_hba.conf` keep working with the internal one.

</details>

<details>
<summary><b>The provider forwards UDP only. Will that work?</b></summary>

No: PostgreSQL works over TCP only. Enable a TCP forward (or TCP+UDP; UDP is simply unused), or connect through a WireGuard/Tailscale tunnel (it runs over UDP) with the `private` mode.

</details>

<details>
<summary><b>Is it safe to allow access from everywhere (`0.0.0.0/0`)?</b></summary>

Better avoid it: the port becomes a brute-force target. Protection remains (SCRAM passwords, SSL, per "database + user" rules), but an IP allowlist, `ufw` and long passwords are much safer. If you must, install a real certificate and connect with `sslmode=verify-full`.

</details>

<details>
<summary><b>How do I install a real SSL certificate?</b></summary>

The default certificate is self-signed: it encrypts traffic but does not prove the server's identity. Get a certificate (for example from Let's Encrypt), copy `fullchain.pem` and `privkey.pem` to a directory readable by `postgres`, and add `/etc/postgresql/<version>/main/conf.d/98-ssl.conf`:

```ini
ssl_cert_file = '/etc/postgresql/17/ssl/fullchain.pem'
ssl_key_file  = '/etc/postgresql/17/ssl/privkey.pem'
```

Then `sudo systemctl reload postgresql` and connect with `sslmode=verify-full`. Do not edit `99-pgmgr.conf`: it is rewritten by `setup`.

</details>

<details>
<summary><b>Why must a custom password use only Latin letters and digits?</b></summary>

So it works without escaping or encoding in URLs, `.env` files, shells and configs. Strength comes from length: generated passwords have 40 characters. For an internet-facing server prefer generation.

</details>

<details>
<summary><b>Can I use the script where PostgreSQL is already installed?</b></summary>

Yes, if it was installed from packages (`apt`) and shows up in `pg_lsclusters`: the script picks up the cluster and does not reinstall it. It will, however, overwrite the performance settings in `conf.d/99-pgmgr.conf` and add its rules to `pg_hba.conf` (the original is kept as `pg_hba.conf.pgmgr.orig`). Take a backup first. Docker or source-built clusters are not supported.

</details>

<details>
<summary><b>How do I run it unattended (cloud-init, Ansible)?</b></summary>

Pass parameters through environment variables and the `-y` flag:

```bash
sudo NETWORK_MODE=public ACCESS_POLICY=list ALLOWED_CIDR="203.0.113.10" DB_PORT=random LANG_UI=en \
     ./pg_server_setup.sh -y setup
```

See [“Environment variables”](#environment-variables) for the full list.

</details>

<details>
<summary><b>Does the script send data anywhere?</b></summary>

No telemetry, and passwords never leave the server. Network access is limited to `apt`/PGDG repositories and — only in `public` mode behind NAT when the IP cannot be found locally — `api.ipify.org`/`ifconfig.me` to learn the external address. Set `PGMGR_HOST` to avoid the latter.

</details>

<details>
<summary><b>How do I turn off colours or change the language?</b></summary>

`NO_COLOR=1` disables colours, `PGMGR_ASCII=1` uses ASCII boxes instead of Unicode, `sudo ./pg_server_setup.sh lang en|ru` changes the language. When output is not a terminal (logs, cron) the decoration turns off automatically.

</details>

<details>
<summary><b>How do I update the script itself?</b></summary>

Leave the menu and run the command from [“Updating the script”](#updating-the-script): it downloads the latest version and safely replaces the file. Saved settings in `/etc/pgmgr/pgmgr.conf` are kept, and new checks are applied by the "Initial setup / re-check" item.

</details>

<details>
<summary><b>How do I remove PostgreSQL and the settings completely?</b></summary>

See [“Removal”](#removal). Take backups first: the data will be lost.

</details>

## Updates

### Updating the script

Leave the script's menu (item `0`) and run one command on the VPS. It downloads the latest version to a new file and replaces the old one:

```bash
cd /root && curl -fsSL https://raw.githubusercontent.com/Poleno7682/postgres-vps-setup/main/pg_server_setup.sh -o pg_server_setup.sh.new && chmod +x pg_server_setup.sh.new && mv pg_server_setup.sh.new pg_server_setup.sh
```

Then start the script as usual; it opens with the new menu:

```bash
sudo ./pg_server_setup.sh
```

- **Your data is untouched.** Databases, users, passwords, `pg_hba.conf` and the saved settings (language, network mode, port, external port in `/etc/pgmgr/pgmgr.conf`) stay as they were.
- **To apply new checks to the system** (regenerate the backup script, the performance settings file and so on) use the "Initial setup / re-check" menu item or `sudo ./pg_server_setup.sh setup --recheck`. PostgreSQL is restarted only if the settings file changed.
- If the script is not in `/root`, replace the path in the first command with yours. If you installed with `git clone`, simply run `git pull` in the repository directory.
- Do not replace the file while the script is running (for example, with the menu open): bash reads a script as it executes, so swapping the file mid-run can break it. That is why the command downloads under another name and swaps it with `mv`.
- To check that the version was updated, look at the file date (`ls -l pg_server_setup.sh`) or at the header of any script screen.

### Updating the system and PostgreSQL

- **PostgreSQL minor updates** (safe, only need a restart): `apt update && apt upgrade`.
- **Re-running `setup`** after a hardware upgrade (for example, more RAM): recalculates the settings and restarts PostgreSQL.
- **Major upgrades** (17 → 18) should be done separately, following the official `pg_upgradecluster` procedure, with a backup taken beforehand.

## Removal

The script does not uninstall PostgreSQL itself. Manual rollback (data will be lost, take backups first):

```bash
sudo systemctl stop postgresql
sudo apt purge -y 'postgresql-*'
sudo rm -f /etc/cron.d/pgmgr-backup /usr/local/sbin/pgmgr-backup \
           /etc/sysctl.d/99-pgmgr.conf
sudo rm -rf /etc/pgmgr
```

Remove the swap file (`/swapfile` and its `/etc/fstab` line) manually if needed.

## License

[MIT](LICENSE) © 2026 Poleno7682

---

<div align="center">

<sub>Made for people who like clear, repeatable deployments. · <a href="#top">Back to top ↑</a></sub>

</div>
