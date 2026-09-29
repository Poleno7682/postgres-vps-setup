#!/usr/bin/env bash
#
# pg_server_setup.sh — initial setup and administration of PostgreSQL on a
# dedicated Ubuntu/Debian VPS. Idempotent: re-running `setup` checks what is
# installed and running and configures only what is missing.
# Messages are available in English and Russian (see LANG_UI / `lang`).
#
# What `setup` does:
#   1. Analyses the server (cores, RAM total/free, disk, swap) and derives
#      PostgreSQL settings from it.
#   2. Asks for the network mode:
#        local   — this server only (listen = localhost);
#        private — private network/VPN (listen = private IP + localhost);
#        public  — public IP: access for EVERYONE (0.0.0.0/0) or only for
#                  selected IPs / ranges.
#   3. Asks for the PostgreSQL port: standard 5432, custom or a random free one
#      (can be changed later with the `port` command).
#   4. Installs PostgreSQL (PGDG), tunes it, hardens defaults, configures swap,
#      backups and (optionally) the ufw firewall.
#
# Isolation model: one cluster, one database per project.
#   * <db>_owner  — database owner (DDL: creates/alters tables, migrations);
#   * <db>_rw     — NOLOGIN group: SELECT/INSERT/UPDATE/DELETE;
#   * <db>_ro     — NOLOGIN group: SELECT only.
# A user's profile on a database = membership in a group
# (owner | readwrite | readonly). PUBLIC has CONNECT and schema rights revoked,
# so a user of one project cannot see or read another project's database.
# Only the public schema is managed.
#
# Usage (as root):
#   ./pg_server_setup.sh                  # interactive menu
#   ./pg_server_setup.sh setup            # initial setup / re-check
#   ./pg_server_setup.sh -y <command> ... # -y: no confirmations (automation)
#   ./pg_server_setup.sh help             # command list
#
# Environment variables (optional; for non-interactive runs):
#   LANG_UI=en|ru                       NETWORK_MODE=local|private|public
#   ACCESS_POLICY=list|all (public)     LISTEN_ADDR=10.0.0.5[,IP2] | '*'
#   ALLOWED_CIDR=203.0.113.10,198.51.100.0/24
#   DB_PORT=default|random|<number>     SERVER_ROLE=dedicated|shared
#   PG_VERSION=17  MAX_CONNECTIONS=<N>  STORAGE=ssd|hdd  SWAP_GB=2
#   BACKUP_DIR=/var/backups/postgresql  BACKUP_RETENTION_DAYS=14
#   PGMGR_PASSWORD=...  (ready-made password for the created/changed user)

set -Eeuo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
readonly SELF
readonly TAG="pgmgr"
readonly CONF_NAME="99-pgmgr.conf"
readonly BACKUP_BIN="/usr/local/sbin/pgmgr-backup"
readonly BACKUP_CRON="/etc/cron.d/pgmgr-backup"
readonly STATE_DIR="/etc/pgmgr"
readonly STATE_FILE="${STATE_DIR}/pgmgr.conf"
readonly MIN_PASSWORD_LEN=12

PG_VERSION="${PG_VERSION:-17}"
MAX_CONNECTIONS="${MAX_CONNECTIONS:-}"      # empty = auto by resources
STORAGE="${STORAGE:-}"                       # empty = auto-detect
SWAP_GB="${SWAP_GB:-2}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/postgresql}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
LANG_UI="${LANG_UI:-}"
ASSUME_YES=0

PG_VER=""
PG_CLUSTER="main"
PG_PORT="5432"
SVC=""
PASSWORD_INPUT=""
CREATED_PASSWORD=""
PASSWORD_GENERATED=0
RESOLVED_CIDRS=""

# Server analysis results (analyze_hardware)
HW_CORES=1; HW_MEM_MB=0; HW_AVAIL_MB=0; HW_SWAP_MB=0
HW_DISK_FREE_GB=0; HW_DISK_TOTAL_GB=0; HW_DISK_PATH="/"
HW_STORAGE_DETECTED="unknown"; HW_VIRT="unknown"

# Network selection results (select_network)
NETWORK_MODE="${NETWORK_MODE:-}"
ACCESS_POLICY="${ACCESS_POLICY:-}"
DEFAULT_CIDRS=""
LISTEN_ADDR="${LISTEN_ADDR:-}"
SERVER_ROLE="${SERVER_ROLE:-}"
IP_CANDS=()

# Port selection (select_port / step_port_config)
DB_PORT="${DB_PORT:-}"
DESIRED_PORT=""
PORT_OLD=""
PORT_CHANGED=0

# ------------------------------------------------------- language / output ----

# L "русский текст" "English text" — picks the text for the current UI language.
L() {
  if [[ "${LANG_UI:-}" == en ]]; then printf '%s' "$2"; else printf '%s' "$1"; fi
}

all_word() { if [[ "${LANG_UI:-}" == en ]]; then printf 'EVERYONE'; else printf 'ВСЕМ'; fi; }

default_lang() { if [[ "${LANG:-}" == ru* ]]; then echo ru; else echo en; fi; }

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

trap 'warn "$(L "Сбой на строке ${LINENO} (команда: ${BASH_COMMAND})" "Failure at line ${LINENO} (command: ${BASH_COMMAND})")"' ERR

require_root() {
  [[ $EUID -eq 0 ]] || die "$(L "Запустите от root: sudo $SELF" "Run as root: sudo $SELF")"
}

ask() { # ask VAR "question" [default]
  local __var="$1" __prompt="$2" __def="${3:-}" __ans=""
  [[ -t 0 ]] || die "$(L "Не хватает аргумента: $__prompt (нет интерактивного ввода)" "Missing argument: $__prompt (no interactive input)")"
  read -r -p "${__prompt}${__def:+ [$__def]}: " __ans || die "$(L "Ввод прерван" "Input interrupted")"
  printf -v "$__var" '%s' "${__ans:-$__def}"
}

pick() { # pick VAR "title" default_number option1 option2 ... -> VAR = number
  local __var="$1" __title="$2" __def="$3" __i=1 __o __pa=""
  shift 3
  echo "$__title"
  for __o in "$@"; do
    printf '  %d) %s\n' "$__i" "$__o"
    __i=$(( __i + 1 ))
  done
  while true; do
    ask __pa "$(L "Выбор" "Choice")" "$__def"
    if [[ "$__pa" =~ ^[0-9]+$ ]] && (( __pa >= 1 && __pa <= $# )); then
      printf -v "$__var" '%s' "$__pa"
      return 0
    fi
    warn "$(L "Введите число от 1 до $#" "Enter a number from 1 to $#")"
  done
}

confirm() {
  if [[ "$ASSUME_YES" == 1 ]]; then return 0; fi
  local a=""
  [[ -t 0 ]] || die "$(L "Нужно подтверждение, но нет интерактивного ввода (используйте -y)" "Confirmation required but no interactive input (use -y)")"
  read -r -p "$1 [y/N] " a || return 1
  [[ "$a" =~ ^[YyДд] ]]
}

confirm_typed() { # requires typing the word/name in full
  if [[ "$ASSUME_YES" == 1 ]]; then return 0; fi
  local a=""
  [[ -t 0 ]] || die "$(L "Нужно подтверждение, но нет интерактивного ввода (используйте -y)" "Confirmation required but no interactive input (use -y)")"
  read -r -p "$(L "Для подтверждения введите '$1': " "Type '$1' to confirm: ")" a || return 1
  [[ "$a" == "$1" ]]
}

gb() { awk -v m="$1" 'BEGIN{printf "%.1f", m/1024}'; }

# ------------------------------------------------------------ validation ----

validate_db() {
  [[ "$1" =~ ^[a-z_][a-z0-9_]{0,59}$ ]] \
    || die "$(L "Недопустимое имя БД '$1' (a-z, 0-9, _; начинается с буквы/_; до 60 символов)" "Invalid database name '$1' (a-z, 0-9, _; must start with a letter/_; up to 60 chars)")"
}

validate_user() {
  [[ "$1" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] \
    || die "$(L "Недопустимое имя пользователя '$1' (a-z, 0-9, _; до 63 символов)" "Invalid user name '$1' (a-z, 0-9, _; up to 63 chars)")"
}

normalize_profile() { # -> owner|readwrite|readonly|none
  case "${1,,}" in
    owner|o)                echo owner ;;
    readwrite|rw|write)     echo readwrite ;;
    readonly|ro|read)       echo readonly ;;
    none|no|-|"")           echo none ;;
    *) die "$(L "Неизвестный профиль '$1' (owner | readwrite | readonly | none)" "Unknown profile '$1' (owner | readwrite | readonly | none)")" ;;
  esac
}

normalize_cidr() { # IPv4[/mask] -> IPv4/mask
  local c="$1" ip mask="32" o
  local -a oct
  [[ "$c" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] || die "$(L "Некорректный IPv4/CIDR: '$c'" "Invalid IPv4/CIDR: '$c'")"
  ip="${c%%/*}"
  if [[ "$c" == */* ]]; then mask="${c##*/}"; fi
  IFS=. read -ra oct <<<"$ip"
  for o in "${oct[@]}"; do
    (( 10#$o <= 255 )) || die "$(L "Некорректный октет в '$c'" "Invalid octet in '$c'")"
  done
  (( 10#$mask <= 32 )) || die "$(L "Некорректная маска в '$c'" "Invalid mask in '$c'")"
  printf '%s/%s\n' "$ip" "$((10#$mask))"
}

normalize_cidr_list() { # "a, b" -> "a/32,b/32"
  local -a items out=()
  local it n
  IFS=, read -ra items <<<"$1"
  for it in "${items[@]}"; do
    it="${it// /}"
    if [[ -z "$it" ]]; then continue; fi
    n="$(normalize_cidr "$it")" || exit 1
    out+=("$n")
  done
  (IFS=,; printf '%s\n' "${out[*]:-}")
}

validate_listen_list() { # "localhost,10.0.0.5" | "*"
  local -a items
  local it
  IFS=, read -ra items <<<"$1"
  for it in "${items[@]}"; do
    it="${it// /}"
    if [[ "$it" == '*' || "$it" == localhost ]]; then continue; fi
    [[ "$it" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "$(L "Некорректный адрес прослушивания: '$it'" "Invalid listen address: '$it'")"
  done
}

cidr_network() { # 10.0.0.5/24 -> 10.0.0.0/24
  local ip="${1%/*}" p="${1#*/}" a b c d n m
  IFS=. read -r a b c d <<<"$ip"
  n=$(( (a << 24) | (b << 16) | (c << 8) | d ))
  m=$(( p == 0 ? 0 : ((0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF) ))
  n=$(( n & m ))
  printf '%d.%d.%d.%d/%d\n' $(( n >> 24 & 255 )) $(( n >> 16 & 255 )) $(( n >> 8 & 255 )) $(( n & 255 )) "$p"
}

is_private_ip() { # RFC1918 + CGNAT 100.64/10 (Tailscale etc.)
  local a b
  IFS=. read -r a b _ <<<"$1"
  (( a == 10 )) || (( a == 172 && b >= 16 && b <= 31 )) \
    || (( a == 192 && b == 168 )) || (( a == 100 && b >= 64 && b <= 127 ))
}

# ------------------------------------------------- state (/etc/pgmgr) ----

state_get() { # state_get KEY
  if [[ -f "$STATE_FILE" ]]; then sed -n "s|^${1}=||p" "$STATE_FILE" | head -n1; fi
}

state_set() { # state_set KEY VALUE
  install -d -m 755 "$STATE_DIR"
  touch "$STATE_FILE"
  chmod 644 "$STATE_FILE"
  if grep -q "^${1}=" "$STATE_FILE"; then
    sed -i "s|^${1}=.*|${1}=${2}|" "$STATE_FILE"
  else
    printf '%s=%s\n' "$1" "$2" >> "$STATE_FILE"
  fi
}

# Language: env LANG_UI > saved > first-run prompt > system $LANG.
init_lang() {
  local l="${LANG_UI:-}" a="" def persist=0
  if [[ -n "$l" ]]; then
    persist=1
  else
    l="$(state_get LANG_UI)"
  fi
  if [[ -z "$l" ]]; then
    def="$(default_lang)"
    if [[ -t 0 && -t 1 ]]; then
      echo "Language / Язык:  1) English   2) Русский"
      read -r -p "[1/2] ($def): " a || a=""
      case "$a" in
        1|en|EN) l=en ;;
        2|ru|RU) l=ru ;;
        *)       l="$def" ;;
      esac
      persist=1
    else
      l="$def"
    fi
  fi
  case "$l" in
    en|ru) ;;
    *) die "LANG_UI must be en or ru" ;;
  esac
  LANG_UI="$l"
  if [[ "$persist" == 1 ]]; then state_set LANG_UI "$l"; fi
}

cmd_lang() { # cmd_lang [en|ru]
  local l="${1:-}" idx=1
  if [[ -z "$l" ]]; then
    pick idx "Language / Язык:" 1 "English" "Русский"
    if (( idx == 1 )); then l=en; else l=ru; fi
  fi
  case "$l" in
    en|ru) ;;
    *) die "Usage: lang [en|ru]" ;;
  esac
  LANG_UI="$l"
  state_set LANG_UI "$l"
  log "$(L "Язык сообщений: русский" "Message language: English")"
}

# ------------------------------------------------------------------ psql ----

psql_admin() {
  runuser -u postgres -- env PGOPTIONS='-c client_min_messages=warning' \
    psql -X -q -v ON_ERROR_STOP=1 "$@"
}

psql_val() { # psql_val "SQL" [db]
  psql_admin -At -d "${2:-postgres}" -c "$1"
}

sql_lit() { printf '%s' "$1" | sed "s/'/''/g"; }

gen_password() { openssl rand -hex 20; }

role_exists() { [[ "$(psql_val "SELECT 1 FROM pg_roles WHERE rolname='$1'")" == 1 ]]; }
db_exists()   { [[ "$(psql_val "SELECT 1 FROM pg_database WHERE datname='$1'")" == 1 ]]; }
db_owner()    { psql_val "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='$1'"; }

reload_pg() { psql_admin -d postgres -c "SELECT pg_reload_conf()" >/dev/null; }

terminate_db_sessions() {
  psql_admin -d postgres -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$1' AND pid <> pg_backend_pid()" >/dev/null
}

# --------------------------------------------------- cluster and service ----

detect_cluster() {
  PG_VER=""; PG_CLUSTER="main"; PG_PORT="5432"; SVC=""
  if command -v pg_lsclusters >/dev/null 2>&1; then
    local line
    line="$(pg_lsclusters -h 2>/dev/null | head -n1 || true)"
    if [[ -n "$line" ]]; then
      PG_VER="$(awk '{print $1}' <<<"$line")"
      PG_CLUSTER="$(awk '{print $2}' <<<"$line")"
      PG_PORT="$(awk '{print $3}' <<<"$line")"
      SVC="postgresql@${PG_VER}-${PG_CLUSTER}"
      export PGPORT="$PG_PORT"
    fi
  fi
}

wait_ready() {
  local i
  for i in $(seq 1 30); do
    if pg_isready -q; then return 0; fi
    sleep 1
  done
  die "$(L "PostgreSQL не отвечает после 30 секунд ожидания (journalctl -u $SVC)" "PostgreSQL is not responding after 30 seconds (journalctl -u $SVC)")"
}

ensure_running() {
  detect_cluster
  [[ -n "$PG_VER" ]] || die "$(L "PostgreSQL не установлен. Сначала выполните: $SELF setup" "PostgreSQL is not installed. Run first: $SELF setup")"
  if ! systemctl is-active --quiet "$SVC"; then
    warn "$(L "PostgreSQL ($SVC) не запущен — запускаю" "PostgreSQL ($SVC) is not running — starting it")"
    systemctl start "$SVC"
  fi
  wait_ready
}

# ------------------------------------------------- server resource analysis ----

detect_storage() { # ssd | hdd | unknown (per kernel data; may be inaccurate on a VPS)
  local src base rota
  src="$(findmnt -no SOURCE -T "$HW_DISK_PATH" 2>/dev/null || true)"
  if [[ -z "$src" ]]; then echo unknown; return 0; fi
  base="$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1 || true)"
  base="${base:-$(basename "$src")}"
  if [[ -r "/sys/block/${base}/queue/rotational" ]]; then
    rota="$(cat "/sys/block/${base}/queue/rotational")"
    if [[ "$rota" == 0 ]]; then echo ssd; else echo hdd; fi
  else
    echo unknown
  fi
}

analyze_hardware() {
  HW_CORES="$(nproc)"
  HW_MEM_MB=$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 1024 ))
  HW_AVAIL_MB=$(( $(awk '/^MemAvailable:/{print $2}' /proc/meminfo) / 1024 ))
  HW_SWAP_MB=$(( $(awk '/^SwapTotal:/{print $2}' /proc/meminfo) / 1024 ))
  HW_DISK_PATH="/var/lib/postgresql"
  if [[ ! -d "$HW_DISK_PATH" ]]; then HW_DISK_PATH="/var"; fi
  HW_DISK_FREE_GB=$(( $(df -Pk "$HW_DISK_PATH" | awk 'NR==2{print $4}') / 1048576 ))
  HW_DISK_TOTAL_GB=$(( $(df -Pk "$HW_DISK_PATH" | awk 'NR==2{print $2}') / 1048576 ))
  HW_STORAGE_DETECTED="$(detect_storage)"
  HW_VIRT="$(systemd-detect-virt 2>/dev/null || true)"
  HW_VIRT="${HW_VIRT:-unknown}"
  if [[ -z "$STORAGE" ]]; then
    # On a VPS virtio disks are often falsely flagged as HDD — treat as HDD on bare metal only.
    if [[ "$HW_STORAGE_DETECTED" == hdd && "$HW_VIRT" == none ]]; then STORAGE=hdd; else STORAGE=ssd; fi
  fi
}

resolve_server_role() { # dedicated | shared
  local r="${SERVER_ROLE:-}"
  if [[ -z "$r" ]]; then r="$(state_get SERVER_ROLE)"; fi
  if [[ -z "$r" ]]; then
    r=dedicated
    if (( HW_AVAIL_MB * 100 < HW_MEM_MB * 60 )) && [[ -t 0 && "$ASSUME_YES" != 1 ]]; then
      warn "$(L "Свободно $(gb "$HW_AVAIL_MB") ГБ из $(gb "$HW_MEM_MB") ГБ — часть памяти занята другими процессами." "Only $(gb "$HW_AVAIL_MB") GB of $(gb "$HW_MEM_MB") GB is free — part of the memory is used by other processes.")"
      confirm "$(L "Сервер выделен под PostgreSQL (использовать всю RAM в расчётах)?" "Is this server dedicated to PostgreSQL (use all RAM in calculations)?")" || r=shared
    fi
  fi
  case "$r" in
    dedicated|shared) ;;
    *) die "$(L "SERVER_ROLE должен быть dedicated или shared" "SERVER_ROLE must be dedicated or shared")" ;;
  esac
  SERVER_ROLE="$r"
  state_set SERVER_ROLE "$r"
}

print_hw_report() {
  local used=$(( HW_MEM_MB - HW_AVAIL_MB ))
  echo "$(L "--- Анализ сервера ---" "--- Server analysis ---")"
  echo "$(L "  CPU:            $HW_CORES ядер" "  CPU:            $HW_CORES cores")"
  echo "$(L "  RAM:            $(gb "$HW_MEM_MB") ГБ всего, $(gb "$HW_AVAIL_MB") ГБ свободно (занято сейчас: $(gb "$used") ГБ)" "  RAM:            $(gb "$HW_MEM_MB") GB total, $(gb "$HW_AVAIL_MB") GB free (in use now: $(gb "$used") GB)")"
  echo "$(L "  Swap:           $(gb "$HW_SWAP_MB") ГБ" "  Swap:           $(gb "$HW_SWAP_MB") GB")"
  echo "$(L "  Диск ($HW_DISK_PATH): $HW_DISK_FREE_GB ГБ свободно из $HW_DISK_TOTAL_GB ГБ" "  Disk ($HW_DISK_PATH): $HW_DISK_FREE_GB GB free of $HW_DISK_TOTAL_GB GB")"
  echo "$(L "  Тип диска:      $STORAGE (ядро сообщает: $HW_STORAGE_DETECTED; виртуализация: $HW_VIRT)" "  Disk type:      $STORAGE (kernel reports: $HW_STORAGE_DETECTED; virtualization: $HW_VIRT)")"
  if (( HW_CORES < 2 )); then warn "$(L "1 ядро: параллельные запросы и автовакуум будут ограничены" "1 core: parallel queries and autovacuum will be limited")"; fi
  if (( HW_MEM_MB < 2000 )); then warn "$(L "RAM меньше 2 ГБ: PostgreSQL будет работать, но на пределе" "Less than 2 GB RAM: PostgreSQL will run, but at its limit")"; fi
  if (( HW_DISK_FREE_GB < 10 )); then warn "$(L "Свободно менее 10 ГБ на диске данных" "Less than 10 GB free on the data disk")"; fi
  if (( HW_AVAIL_MB * 100 < HW_MEM_MB * 50 )); then
    warn "$(L "Больше половины RAM занято другими процессами — для БД лучше выделенный сервер" "More than half of RAM is used by other processes — a dedicated server is better for a database")"
  fi
}

# ------------------------------------------------- pg_hba.conf and firewall ----

hba_file() { psql_val "SHOW hba_file"; }

hba_drop_line() { # hba_drop_line file "exact line"
  local f="$1" line="$2"
  grep -vxF -- "$line" "$f" > "$f.pgmgr.tmp" || true
  cat "$f.pgmgr.tmp" > "$f"
  rm -f "$f.pgmgr.tmp"
}

ufw_active() { command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; }

ufw_allow() { # cidr; 0.0.0.0/0 = from anywhere
  if ufw_active; then
    if [[ "$1" == "0.0.0.0/0" ]]; then
      ufw allow "${PG_PORT}/tcp" >/dev/null
      log "$(L "ufw: разрешён ${PG_PORT}/tcp отовсюду" "ufw: allowed ${PG_PORT}/tcp from anywhere")"
    else
      ufw allow from "$1" to any port "$PG_PORT" proto tcp >/dev/null
      log "$(L "ufw: разрешён $1 -> ${PG_PORT}/tcp" "ufw: allowed $1 -> ${PG_PORT}/tcp")"
    fi
  fi
}

hba_add() { # hba_add db user cidr
  local db="$1" u="$2" cidr line f errs
  cidr="$(normalize_cidr "$3")"
  f="$(hba_file)"
  line="hostssl ${db} ${u} ${cidr} scram-sha-256 # ${TAG}:${db}:${u}"
  cp -n "$f" "$f.pgmgr.orig" || true
  if grep -qxF -- "$line" "$f"; then
    log "$(L "Правило pg_hba уже есть: $db / $u / $cidr" "pg_hba rule already exists: $db / $u / $cidr")"
  else
    if [[ -n "$(tail -c1 "$f")" ]]; then echo >> "$f"; fi
    printf '%s\n' "$line" >> "$f"
    errs="$(psql_val "SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL")"
    if [[ "$errs" != 0 ]]; then
      hba_drop_line "$f" "$line"
      die "$(L "pg_hba.conf стал некорректным — правило откатено" "pg_hba.conf became invalid — the rule was rolled back")"
    fi
    reload_pg
    log "$(L "pg_hba: разрешён $u к $db с $cidr (hostssl, scram-sha-256)" "pg_hba: allowed $u to $db from $cidr (hostssl, scram-sha-256)")"
  fi
  if [[ "$(psql_val 'SHOW listen_addresses')" == "localhost" ]]; then
    warn "$(L "listen_addresses=localhost — удалённые подключения не заработают. Смените режим сети: $SELF network" "listen_addresses=localhost — remote connections will not work. Change the network mode: $SELF network")"
  fi
  ufw_allow "$cidr"
}

apply_access() { # apply_access db user "cidr1,cidr2"
  local db="$1" u="$2" list="$3" c
  local -a arr
  if [[ -z "$list" ]]; then return 0; fi
  IFS=, read -ra arr <<<"$list"
  for c in "${arr[@]}"; do
    if [[ -n "$c" ]]; then hba_add "$db" "$u" "$c"; fi
  done
}

# Where to allow a new user/database from: argument, otherwise the network-mode default.
# Result in RESOLVED_CIDRS (comma separated, may be empty = local only).
resolve_cidrs() {
  local arg="${1:-}" def mode
  RESOLVED_CIDRS=""
  mode="$(state_get NETWORK_MODE)"
  def="$(state_get DEFAULT_CIDRS)"
  def="${def:-${ALLOWED_CIDR:-}}"
  if [[ -z "$arg" ]]; then
    if [[ "${mode:-local}" == local && -z "$def" ]]; then return 0; fi
    if [[ -t 0 && "$ASSUME_YES" != 1 ]]; then
      ask arg "$(L "Откуда разрешён доступ (IP/CIDR через запятую, '-' — только локально)" "Allowed source (comma-separated IP/CIDR, '-' = local only)")" "${def:--}"
    else
      arg="$def"
    fi
  fi
  case "$arg" in
    -|none|"") return 0 ;;
  esac
  RESOLVED_CIDRS="$(normalize_cidr_list "$arg")" || exit 1
}

hba_del() { # hba_del db user  (db/user = '*' -> any)
  local db="$1" u="$2" f pat
  f="$(hba_file)"
  if [[ "$db" == "*" ]]; then db='[a-z0-9_]*'; fi
  if [[ "$u" == "*" ]]; then u='[a-z0-9_]*'; fi
  pat="# ${TAG}:${db}:${u}\$"
  cp -n "$f" "$f.pgmgr.orig" || true
  sed -i "/${pat}/d" "$f"
  reload_pg
}

# ------------------------------------------------------- network mode ----

collect_ips() { # collect_ips private|public -> IP_CANDS ("iface ip/prefix")
  IP_CANDS=()
  local iface cidr ip
  while read -r iface cidr; do
    if [[ -z "$iface" ]]; then continue; fi
    if [[ "$iface" =~ ^(docker|br-|veth|virbr|cni|flannel|lxc|cali) ]]; then continue; fi
    ip="${cidr%/*}"
    if is_private_ip "$ip"; then
      if [[ "$1" == private ]]; then IP_CANDS+=("$iface $cidr"); fi
    else
      if [[ "$1" == public ]]; then IP_CANDS+=("$iface $cidr"); fi
    fi
  done < <(ip -4 -o addr show scope global | awk '{print $2, $4}')
}

ip_of() { awk '{split($2, a, "/"); print a[1]}' <<<"$1"; }

select_network() { # select_network [force=0]
  local force="${1:-0}" mode="${NETWORK_MODE:-}" policy="${ACCESS_POLICY:-}"
  local cidrs="${ALLOWED_CIDR:-}" listen_in="${LISTEN_ADDR:-}" listen_val="" final idx=1 net=""
  local saved_mode saved_policy def_idx=1
  local -a opts
  saved_mode="$(state_get NETWORK_MODE)"
  saved_policy="$(state_get ACCESS_POLICY)"

  if [[ -z "$mode" && -n "$saved_mode" && "$force" != 1 ]]; then
    NETWORK_MODE="$saved_mode"
    LISTEN_ADDR="$(state_get LISTEN_ADDR)"
    ACCESS_POLICY="$saved_policy"
    DEFAULT_CIDRS="$(state_get DEFAULT_CIDRS)"
    log "$(L "Сеть (из сохранённых настроек): ${NETWORK_MODE}, listen=${LISTEN_ADDR}, доступ=${ACCESS_POLICY:-none} ${DEFAULT_CIDRS}" "Network (from saved settings): ${NETWORK_MODE}, listen=${LISTEN_ADDR}, access=${ACCESS_POLICY:-none} ${DEFAULT_CIDRS}")"
    return 0
  fi

  if [[ -z "$mode" ]]; then
    if [[ -t 0 ]]; then
      case "$saved_mode" in private) def_idx=2 ;; public) def_idx=3 ;; esac
      pick idx "$(L "Режим доступа к PostgreSQL:" "PostgreSQL access mode:")" "$def_idx" \
        "$(L "local   — только этот сервер (localhost): приложения работают на самом VPS" "local   — this server only (localhost): applications run on the VPS itself")" \
        "$(L "private — приватная сеть / VPN (WireGuard, Tailscale, VPC): слушать приватный IP" "private — private network / VPN (WireGuard, Tailscale, VPC): listen on a private IP")" \
        "$(L "public  — публичный IP: доступ для ВСЕХ или только для выбранных IP/диапазонов" "public  — public IP: access for EVERYONE or only for selected IPs/ranges")"
      case "$idx" in 1) mode=local ;; 2) mode=private ;; 3) mode=public ;; esac
    else
      mode=local
      warn "$(L "Режим сети не задан (нет интерактива и NETWORK_MODE) — использую local" "Network mode not set (no interactive input and no NETWORK_MODE) — using local")"
    fi
  fi

  case "$mode" in
    local)
      listen_val=""; policy="none"; cidrs=""
      ;;
    private)
      collect_ips private
      if [[ -n "$listen_in" ]]; then
        listen_val="$listen_in"
      elif (( ${#IP_CANDS[@]} > 0 )); then
        if [[ -t 0 ]]; then
          pick idx "$(L "Приватные адреса этого сервера:" "Private addresses of this server:")" 1 "${IP_CANDS[@]}"
          net="${IP_CANDS[idx-1]}"
        else
          net="${IP_CANDS[0]}"
        fi
        listen_val="$(ip_of "$net")"
        if [[ -z "$cidrs" ]]; then cidrs="$(cidr_network "$(awk '{print $2}' <<<"$net")")"; fi
      else
        [[ -t 0 ]] || die "$(L "Приватный IP не найден: задайте LISTEN_ADDR" "No private IP found: set LISTEN_ADDR")"
        warn "$(L "Приватных адресов (10.x/172.16-31.x/192.168.x/100.64.x) не найдено. Создайте приватную сеть/VPN или укажите IP вручную." "No private addresses (10.x/172.16-31.x/192.168.x/100.64.x) found. Create a private network/VPN or enter the IP manually.")"
        ask listen_val "$(L "Приватный IP для прослушивания" "Private IP to listen on")"
      fi
      policy="list"
      if [[ -t 0 && "$ASSUME_YES" != 1 ]]; then
        ask cidrs "$(L "Кому разрешить доступ (сети/IP клиентов, через запятую)" "Who may connect (client networks/IPs, comma-separated)")" "$cidrs"
      fi
      [[ -n "$cidrs" ]] || die "$(L "Не задан список разрешённых клиентов (ALLOWED_CIDR)" "No allowed clients specified (ALLOWED_CIDR)")"
      ;;
    public)
      collect_ips public
      if [[ -n "$listen_in" ]]; then
        listen_val="$listen_in"
      else
        opts=("${IP_CANDS[@]}" "$(L "* — все интерфейсы (сервер за NAT или несколько IP)" "* — all interfaces (server behind NAT or several IPs)")")
        if [[ -t 0 ]]; then
          pick idx "$(L "Публичные адреса этого сервера (на каком слушать):" "Public addresses of this server (which one to listen on):")" 1 "${opts[@]}"
          if (( idx == ${#opts[@]} )); then listen_val='*'; else listen_val="$(ip_of "${IP_CANDS[idx-1]}")"; fi
        elif (( ${#IP_CANDS[@]} > 0 )); then
          listen_val="$(ip_of "${IP_CANDS[0]}")"
        else
          listen_val='*'
        fi
      fi
      if [[ -z "$policy" ]]; then
        if [[ -t 0 ]]; then
          pick idx "$(L "Кто может подключаться:" "Who may connect:")" 1 \
            "$(L "Только определённые IP / диапазоны (рекомендуется)" "Only specific IPs / ranges (recommended)")" \
            "$(L "Все (0.0.0.0/0) — защита только паролем + SSL, открыто всему интернету" "Everyone (0.0.0.0/0) — protected only by password + SSL, open to the whole internet")"
          if (( idx == 1 )); then policy=list; else policy=all; fi
        else
          die "$(L "Для public задайте ACCESS_POLICY=list|all" "For public set ACCESS_POLICY=list|all")"
        fi
      fi
      case "$policy" in
        list)
          if [[ -z "$cidrs" ]]; then
            [[ -t 0 ]] || die "$(L "Для ACCESS_POLICY=list задайте ALLOWED_CIDR" "For ACCESS_POLICY=list set ALLOWED_CIDR")"
            while [[ -z "$cidrs" ]]; do
              ask cidrs "$(L "Разрешённые IP/диапазоны (например 203.0.113.10, 198.51.100.0/24)" "Allowed IPs/ranges (e.g. 203.0.113.10, 198.51.100.0/24)")"
            done
          fi
          ;;
        all)
          warn "$(L "Порт PostgreSQL будет доступен всему интернету. Защита: scram-sha-256, SSL, правила по БД/пользователю — но брутфорс возможен." "The PostgreSQL port will be reachable from the whole internet. Protection: scram-sha-256, SSL, per-database/user rules — but brute force is possible.")"
          confirm_typed "$(all_word)" || die "$(L "Отменено" "Cancelled")"
          cidrs="0.0.0.0/0"
          ;;
        *) die "$(L "ACCESS_POLICY должен быть list или all" "ACCESS_POLICY must be list or all")" ;;
      esac
      ;;
    *) die "$(L "NETWORK_MODE должен быть local, private или public" "NETWORK_MODE must be local, private or public")" ;;
  esac

  if [[ -n "$listen_val" ]]; then validate_listen_list "$listen_val"; fi
  if [[ -n "$cidrs" ]]; then cidrs="$(normalize_cidr_list "$cidrs")" || exit 1; fi

  if [[ "$listen_val" == *'*'* ]]; then
    final='*'
  elif [[ -z "$listen_val" ]]; then
    final="localhost"
  else
    final="localhost,${listen_val// /}"
  fi

  NETWORK_MODE="$mode"; ACCESS_POLICY="$policy"; DEFAULT_CIDRS="$cidrs"; LISTEN_ADDR="$final"
  state_set NETWORK_MODE "$mode"
  state_set ACCESS_POLICY "$policy"
  state_set DEFAULT_CIDRS "$cidrs"
  state_set LISTEN_ADDR "$final"
  log "$(L "Сеть: режим=${mode}, listen=${final}, доступ=${policy} ${cidrs}" "Network: mode=${mode}, listen=${final}, access=${policy} ${cidrs}")"
  if [[ -n "$saved_mode" && ( "$saved_mode" != "$mode" || "$saved_policy" != "$policy" ) ]]; then
    warn "$(L "Режим изменён. Старые правила pg_hba могли остаться — проверьте: $SELF list" "Mode changed. Old pg_hba rules may remain — check: $SELF list")"
  fi
}

apply_ufw_defaults() { # PG port only for clients of the selected network mode
  local mode c
  local -a arr
  mode="$(state_get NETWORK_MODE)"
  if [[ "$mode" != public && "$mode" != private ]]; then return 0; fi
  if ufw_active; then
    IFS=, read -ra arr <<<"$(state_get DEFAULT_CIDRS)"
    for c in "${arr[@]}"; do
      if [[ -n "$c" ]]; then ufw_allow "$c"; fi
    done
  elif [[ "$mode" == public ]]; then
    warn "$(L "ufw не активен: порт ${PG_PORT} защищён только pg_hba.conf. Рекомендуется: $SELF firewall-init" "ufw is not active: port ${PG_PORT} is protected only by pg_hba.conf. Recommended: $SELF firewall-init")"
  fi
}

# ------------------------------------------------------------- port ----

port_in_use() { [[ -n "$(ss -H -ltn "sport = :$1" 2>/dev/null)" ]]; }

ssh_port() {
  local p
  p="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"
  echo "${p:-22}"
}

validate_port() { # number 1024-65535, not SSH, not used by another process
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || die "$(L "Порт должен быть числом: '$p'" "Port must be a number: '$p'")"
  (( p >= 1024 && p <= 65535 )) || die "$(L "Порт вне диапазона 1024-65535: $p" "Port out of range 1024-65535: $p")"
  if [[ "$p" == "$(ssh_port)" ]]; then die "$(L "Порт $p занят под SSH" "Port $p is used by SSH")"; fi
  if [[ "$p" != "$PG_PORT" ]] && port_in_use "$p"; then die "$(L "Порт $p уже занят другим процессом" "Port $p is already used by another process")"; fi
}

random_free_port() {
  local i p
  for i in $(seq 1 50); do
    p="$(shuf -i 10000-32000 -n1)"
    if [[ "$p" != "$(ssh_port)" ]] && ! port_in_use "$p"; then echo "$p"; return 0; fi
  done
  die "$(L "Не удалось подобрать свободный порт" "Could not find a free port")"
}

# Port choice: standard 5432 / custom / random free. Changes nothing, only sets
# DESIRED_PORT. A saved choice is not asked again.
select_port() { # select_port [force=0]
  local force="${1:-0}" choice="${DB_PORT:-}" saved idx=1
  saved="$(state_get DB_PORT)"

  if [[ -z "$choice" && -n "$saved" && "$force" != 1 ]]; then
    DESIRED_PORT="$saved"
    log "$(L "Порт (из сохранённых настроек): $DESIRED_PORT" "Port (from saved settings): $DESIRED_PORT")"
    return 0
  fi

  if [[ -z "$choice" ]]; then
    if [[ -t 0 ]]; then
      pick idx "$(L "Порт PostgreSQL (сейчас: ${PG_PORT}):" "PostgreSQL port (current: ${PG_PORT}):")" 1 \
        "$(L "Стандартный 5432" "Standard 5432")" \
        "$(L "Свой порт" "Custom port")" \
        "$(L "Случайный свободный порт" "Random free port")"
      case "$idx" in
        1) choice=default ;;
        2) ask choice "$(L "Введите порт (1024-65535)" "Enter a port (1024-65535)")" ;;
        3) choice=random ;;
      esac
    else
      choice="${saved:-$PG_PORT}"
    fi
  fi

  case "$choice" in
    default) DESIRED_PORT=5432 ;;
    random)  DESIRED_PORT="$(random_free_port)" ;;
    *)       DESIRED_PORT="$choice" ;;
  esac
  validate_port "$DESIRED_PORT"
  log "$(L "Выбран порт PostgreSQL: $DESIRED_PORT" "PostgreSQL port selected: $DESIRED_PORT")"
}

# Writes the port to the cluster's postgresql.conf (pg_conftool). Caller restarts.
step_port_config() {
  PORT_CHANGED=0
  if [[ "$DESIRED_PORT" == "$PG_PORT" ]]; then
    log "$(L "Порт PostgreSQL: $PG_PORT" "PostgreSQL port: $PG_PORT")"
    state_set DB_PORT "$PG_PORT"
    return 0
  fi
  PORT_OLD="$PG_PORT"
  pg_conftool "$PG_VER" "$PG_CLUSTER" set port "$DESIRED_PORT"
  PORT_CHANGED=1
  log "$(L "Порт в конфигурации: $PORT_OLD -> $DESIRED_PORT (применится после перезапуска)" "Port in configuration: $PORT_OLD -> $DESIRED_PORT (applies after restart)")"
}

managed_cidrs() { # CIDRs of the script's pg_hba rules + network-mode networks
  local f
  f="$(hba_file)"
  { grep "# ${TAG}:" "$f" || true; } | awk '{print $4}'
  state_get DEFAULT_CIDRS | tr ',' '\n'
}

migrate_ufw_port() { # migrate_ufw_port old new
  local old="$1" new="$2" c
  if ! ufw_active; then
    if [[ "$(state_get NETWORK_MODE)" == public ]]; then
      warn "$(L "ufw не активен: порт $new защищён только pg_hba.conf. Рекомендуется: $SELF firewall-init" "ufw is not active: port $new is protected only by pg_hba.conf. Recommended: $SELF firewall-init")"
    fi
    return 0
  fi
  while read -r c; do
    if [[ -z "$c" ]]; then continue; fi
    if [[ "$c" == "0.0.0.0/0" ]]; then
      ufw --force delete allow "${old}/tcp" >/dev/null 2>&1 || true
    else
      ufw --force delete allow from "$c" to any port "$old" proto tcp >/dev/null 2>&1 || true
    fi
    ufw_allow "$c"
  done < <(managed_cidrs | sort -u)
  log "$(L "ufw: правила перенесены с порта $old на $new" "ufw: rules migrated from port $old to $new")"
}

# Call after PostgreSQL restarted and detect_cluster ran with the new port.
step_port_finish() {
  if [[ "$PORT_CHANGED" != 1 ]]; then return 0; fi
  if [[ "$(psql_val 'SHOW port')" != "$DESIRED_PORT" ]]; then
    die "$(L "PostgreSQL слушает не порт $DESIRED_PORT (проверьте conf.d и journalctl -u $SVC)" "PostgreSQL is not listening on port $DESIRED_PORT (check conf.d and journalctl -u $SVC)")"
  fi
  state_set DB_PORT "$DESIRED_PORT"
  migrate_ufw_port "$PORT_OLD" "$DESIRED_PORT"
  PORT_CHANGED=0
  warn "$(L "Порт изменён: $PORT_OLD -> $DESIRED_PORT. Обновите строки подключения приложений; локально: psql -p $DESIRED_PORT" "Port changed: $PORT_OLD -> $DESIRED_PORT. Update your applications' connection strings; locally: psql -p $DESIRED_PORT")"
}

cmd_port() { # cmd_port [port|default|random]
  ensure_running
  local arg="${1:-}"
  if [[ -n "$arg" ]]; then DB_PORT="$arg"; fi
  select_port 1
  step_port_config
  if [[ "$PORT_CHANGED" == 1 ]]; then
    warn "$(L "PostgreSQL будет перезапущен, активные подключения оборвутся." "PostgreSQL will be restarted, active connections will be dropped.")"
    confirm "$(L "Сменить порт $PORT_OLD -> $DESIRED_PORT?" "Change the port $PORT_OLD -> $DESIRED_PORT?")" || {
      pg_conftool "$PG_VER" "$PG_CLUSTER" set port "$PORT_OLD"; PORT_CHANGED=0; log "$(L "Отменено" "Cancelled")"; return 0; }
    systemctl restart "$SVC"
    detect_cluster
    wait_ready
    step_port_finish
    if [[ -x "$BACKUP_BIN" ]]; then step_backup; fi
  fi
}

# IP clients use to connect to this server (by network mode).
connect_host() {
  local mode listen it
  local -a items
  mode="$(state_get NETWORK_MODE)"
  listen="$(state_get LISTEN_ADDR)"
  if [[ "$mode" == local || -z "$listen" ]]; then echo "127.0.0.1"; return 0; fi
  if [[ "$listen" != '*' ]]; then
    IFS=, read -ra items <<<"$listen"
    for it in "${items[@]}"; do
      if [[ "$it" != localhost ]]; then echo "$it"; return 0; fi
    done
    echo "127.0.0.1"; return 0
  fi
  collect_ips "$mode"
  if (( ${#IP_CANDS[@]} > 0 )); then ip_of "${IP_CANDS[0]}"; return 0; fi
  echo "<SERVER_IP>"
}

print_network_summary() {
  echo "$(L "--- Сеть ---" "--- Network ---")"
  echo "$(L "  IP подключения: $(connect_host)" "  Connect IP:     $(connect_host)")"
  echo "$(L "  Режим:          $(state_get NETWORK_MODE)" "  Mode:           $(state_get NETWORK_MODE)")"
  echo "$(L "  listen:         $(state_get LISTEN_ADDR) (порт $PG_PORT)" "  listen:         $(state_get LISTEN_ADDR) (port $PG_PORT)")"
  echo "$(L "  Политика:       $(state_get ACCESS_POLICY)" "  Policy:         $(state_get ACCESS_POLICY)")"
  echo "$(L "  Клиенты:        $(state_get DEFAULT_CIDRS)" "  Clients:        $(state_get DEFAULT_CIDRS)")"
  if [[ "$(state_get NETWORK_MODE)" == public ]]; then
    echo "$(L "  SSL:            сертификат по умолчанию самоподписанный: шифрует, но не подтверждает сервер." "  SSL:            the default certificate is self-signed: it encrypts but does not verify the server.")"
    echo "$(L "                  Для sslmode=verify-full установите свой сертификат (например Let's Encrypt)." "                  For sslmode=verify-full install your own certificate (e.g. Let's Encrypt).")"
  fi
}

# -------------------------------------------- roles, groups, owners ----

# Password choice: enter your own or generate. -> PASSWORD_INPUT, PASSWORD_GENERATED
choose_password() { # choose_password "for whom"
  local who="$1" mode=1 p1 p2
  PASSWORD_GENERATED=0
  if [[ -n "${PGMGR_PASSWORD:-}" ]]; then
    PASSWORD_INPUT="$PGMGR_PASSWORD"
    (( ${#PASSWORD_INPUT} >= MIN_PASSWORD_LEN )) || die "$(L "Пароль короче ${MIN_PASSWORD_LEN} символов" "Password is shorter than ${MIN_PASSWORD_LEN} characters")"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    PASSWORD_INPUT="$(gen_password)"; PASSWORD_GENERATED=1
    return 0
  fi
  pick mode "$(L "Пароль для '$who':" "Password for '$who':")" 1 \
    "$(L "Сгенерировать надёжный случайный (рекомендуется)" "Generate a strong random one (recommended)")" \
    "$(L "Ввести свой" "Enter my own")"
  if (( mode == 1 )); then
    PASSWORD_INPUT="$(gen_password)"; PASSWORD_GENERATED=1
    return 0
  fi
  while true; do
    read -rs -p "$(L "Введите пароль (минимум ${MIN_PASSWORD_LEN} символов): " "Enter the password (at least ${MIN_PASSWORD_LEN} characters): ")" p1 || die "$(L "Ввод прерван" "Input interrupted")"; echo
    if (( ${#p1} < MIN_PASSWORD_LEN )); then warn "$(L "Слишком короткий пароль" "Password too short")"; continue; fi
    read -rs -p "$(L "Повторите пароль: " "Repeat the password: ")" p2 || die "$(L "Ввод прерван" "Input interrupted")"; echo
    if [[ "$p1" != "$p2" ]]; then warn "$(L "Пароли не совпадают" "Passwords do not match")"; continue; fi
    PASSWORD_INPUT="$p1"
    if [[ "$p1" =~ [@:/?#%\ ] ]]; then
      warn "$(L "В пароле есть спецсимволы (@ : / ? # % пробел) — в URL-строке подключения их нужно кодировать (percent-encoding)." "The password contains special characters (@ : / ? # % space) — they must be percent-encoded in a connection URL.")"
    fi
    return 0
  done
}

create_login_role() { # -> CREATED_PASSWORD (empty if the role already existed)
  local u="$1" esc
  CREATED_PASSWORD=""
  if role_exists "$u"; then
    log "$(L "Пользователь '$u' уже существует — пароль не меняю" "User '$u' already exists — password unchanged")"
    return 0
  fi
  choose_password "$u"
  esc="$(sql_lit "$PASSWORD_INPUT")"
  psql_admin -d postgres <<SQL
CREATE ROLE "$u" LOGIN PASSWORD '$esc' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
SQL
  CREATED_PASSWORD="$PASSWORD_INPUT"
  log "$(L "Создан пользователь '$u'" "User '$u' created")"
}

# Databases the user can access (owner or rw/ro profile).
user_databases() {
  psql_val "SELECT COALESCE(string_agg(db, ', ' ORDER BY db), '—') FROM (SELECT datname AS db FROM pg_database WHERE datdba=(SELECT oid FROM pg_roles WHERE rolname='$1') UNION SELECT regexp_replace(g.rolname, '_(rw|ro)\$', '') FROM pg_auth_members am JOIN pg_roles g ON g.oid=am.roleid JOIN pg_roles m ON m.oid=am.member WHERE m.rolname='$1' AND g.rolname ~ '_(rw|ro)\$') t"
}

# Final connection details. The password is shown ONCE: after printing it is
# wiped from the script's memory and never printed again.
show_credentials() { # user [db]
  [[ -n "$CREATED_PASSWORD" ]] || return 0
  local u="$1" db="${2:-}"
  if [[ -z "$db" ]]; then db="$(user_databases "$u")"; fi
  echo
  echo "$(L "=================== Данные для подключения ===================" "==================== Connection details ====================")"
  echo "$(L "  IP:           $(connect_host)" "  IP:           $(connect_host)")"
  echo "$(L "  Порт:         $PG_PORT" "  Port:         $PG_PORT")"
  echo "$(L "  Название БД:  $db" "  Database:     $db")"
  echo "$(L "  Логин:        $u" "  Login:        $u")"
  echo "$(L "  Пароль:       $CREATED_PASSWORD" "  Password:     $CREATED_PASSWORD")"
  echo "  SSL:          sslmode=require"
  echo "--------------------------------------------------------------"
  echo "$(L "  Пароль показан один раз — сохраните его сейчас." "  The password is shown only once — save it now.")"
  echo "=============================================================="
  echo
  CREATED_PASSWORD=""
  PASSWORD_INPUT=""
}

# Creates (idempotently) groups <db>_rw / <db>_ro and their privileges,
# including DEFAULT PRIVILEGES for future tables of the database owner.
ensure_db_groups() {
  local db="$1" owner suf
  owner="$(db_owner "$db")"
  for suf in rw ro; do
    if ! role_exists "${db}_${suf}"; then
      psql_admin -d postgres -c "CREATE ROLE \"${db}_${suf}\" NOLOGIN"
    fi
  done
  psql_admin -d "$db" <<SQL
GRANT CONNECT ON DATABASE "$db" TO "${db}_rw", "${db}_ro";
GRANT USAGE ON SCHEMA public TO "${db}_rw", "${db}_ro";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "${db}_rw";
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO "${db}_rw";
GRANT SELECT ON ALL TABLES IN SCHEMA public TO "${db}_ro";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO "${db}_ro";
ALTER DEFAULT PRIVILEGES FOR ROLE "$owner" IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "${db}_rw";
ALTER DEFAULT PRIVILEGES FOR ROLE "$owner" IN SCHEMA public
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO "${db}_rw";
ALTER DEFAULT PRIVILEGES FOR ROLE "$owner" IN SCHEMA public
  GRANT SELECT ON TABLES TO "${db}_ro";
ALTER DEFAULT PRIVILEGES FOR ROLE "$owner" IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO "${db}_ro";
SQL
}

set_db_owner() { # set_db_owner db newowner
  local db="$1" u="$2" old others
  old="$(db_owner "$db")"
  if [[ "$old" == "$u" ]]; then log "$(L "'$u' уже владелец '$db'" "'$u' is already the owner of '$db'")"; return 0; fi
  terminate_db_sessions "$db"
  psql_admin -d postgres -c "ALTER DATABASE \"$db\" OWNER TO \"$u\""
  psql_admin -d "$db" -c "ALTER SCHEMA public OWNER TO \"$u\""
  if [[ "$old" != "postgres" ]]; then
    others="$(psql_val "SELECT count(*) FROM pg_database WHERE datdba=(SELECT oid FROM pg_roles WHERE rolname='$old')")"
    if [[ "$others" == 0 ]]; then
      psql_admin -d "$db" -c "REASSIGN OWNED BY \"$old\" TO \"$u\""
    else
      warn "$(L "'$old' владеет и другими БД — объекты внутри '$db' остались за ним (REASSIGN не выполнялся)" "'$old' owns other databases too — objects inside '$db' stay with it (REASSIGN was not run)")"
    fi
  fi
  ensure_db_groups "$db"
  log "$(L "Владелец '$db' теперь '$u'" "The owner of '$db' is now '$u'")"
}

set_membership() { # set_membership db user profile(readwrite|readonly|none)
  local db="$1" u="$2" p="$3"
  psql_admin -d postgres <<SQL
REVOKE "${db}_rw" FROM "$u";
REVOKE "${db}_ro" FROM "$u";
SQL
  case "$p" in
    readwrite) psql_admin -d postgres -c "GRANT \"${db}_rw\" TO \"$u\"" ;;
    readonly)  psql_admin -d postgres -c "GRANT \"${db}_ro\" TO \"$u\"" ;;
  esac
}

apply_profile() { # apply_profile db user profile
  local db="$1" u="$2" p="$3"
  ensure_db_groups "$db"
  case "$p" in
    owner)
      set_membership "$db" "$u" none
      set_db_owner "$db" "$u"
      ;;
    readwrite|readonly)
      if [[ "$(db_owner "$db")" == "$u" ]]; then
        die "$(L "'$u' — владелец '$db'. Сначала передайте владение: $SELF db-chown $db <другой_пользователь>" "'$u' is the owner of '$db'. Transfer ownership first: $SELF db-chown $db <other_user>")"
      fi
      set_membership "$db" "$u" "$p"
      log "'$u' -> '$db': $p"
      ;;
    none)
      if [[ "$(db_owner "$db")" == "$u" ]]; then
        die "$(L "'$u' — владелец '$db'. Сначала передайте владение: $SELF db-chown $db <другой_пользователь>" "'$u' is the owner of '$db'. Transfer ownership first: $SELF db-chown $db <other_user>")"
      fi
      set_membership "$db" "$u" none
      log "$(L "У '$u' отозван доступ к '$db'" "Access of '$u' to '$db' revoked")"
      ;;
  esac
}

# ------------------------------------------------------------ setup ----

install_postgres() {
  export DEBIAN_FRONTEND=noninteractive
  log "$(L "Устанавливаю PostgreSQL ${PG_VERSION} из репозитория PGDG" "Installing PostgreSQL ${PG_VERSION} from the PGDG repository")"
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates gnupg lsb-release openssl postgresql-common
  /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
  apt-get install -y -qq "postgresql-${PG_VERSION}"
}

# Parameter calculation for this server (cores, RAM, disk type, role, network).
render_tuning() {
  local budget sb ecs mwm wm maxc cap rpc eio wal wproc pgath pmaint avw
  budget="$HW_MEM_MB"
  if [[ "$SERVER_ROLE" == shared ]]; then budget=$(( HW_MEM_MB / 2 )); fi

  maxc="$MAX_CONNECTIONS"
  if [[ -z "$maxc" ]]; then
    maxc=$(( (HW_MEM_MB / 40 + 24) / 25 * 25 ))
    cap=$(( HW_CORES * 50 ))
    if (( maxc > cap )); then maxc=$cap; fi
    if (( maxc < 50 )); then maxc=50; fi
    if (( maxc > 300 )); then maxc=300; fi
  fi

  sb=$(( budget / 4 ))
  ecs=$(( budget * 3 / 4 ))
  mwm=$(( budget / 16 )); if (( mwm > 1024 )); then mwm=1024; fi
  wm=$(( (budget - sb) / (maxc * 3) ))
  if (( wm < 4 )); then wm=4; fi
  if (( wm > 64 )); then wm=64; fi

  wproc=$(( HW_CORES > 8 ? HW_CORES : 8 ))
  pgath=$(( HW_CORES / 2 )); if (( pgath < 1 )); then pgath=1; fi; if (( pgath > 4 )); then pgath=4; fi
  pmaint=$pgath
  if (( HW_CORES >= 4 )); then avw=4; else avw=3; fi

  if [[ "$STORAGE" == "hdd" ]]; then rpc="4.0"; eio=2; else rpc="1.1"; eio=200; fi
  if (( HW_MEM_MB >= 8000 )); then wal="4GB"; else wal="2GB"; fi

  cat <<EOF
# Managed by pg_server_setup.sh — do not edit by hand (overwritten on setup).
# CPU: ${HW_CORES} cores, RAM: ${HW_MEM_MB} MB (budget ${budget} MB, role: ${SERVER_ROLE}), disk: ${STORAGE}
# Network: ${NETWORK_MODE}
listen_addresses = '${LISTEN_ADDR}'
max_connections = ${maxc}
password_encryption = scram-sha-256

shared_buffers = ${sb}MB
effective_cache_size = ${ecs}MB
work_mem = ${wm}MB
maintenance_work_mem = ${mwm}MB
wal_buffers = 16MB

max_worker_processes = ${wproc}
max_parallel_workers = ${HW_CORES}
max_parallel_workers_per_gather = ${pgath}
max_parallel_maintenance_workers = ${pmaint}
autovacuum_max_workers = ${avw}

checkpoint_timeout = 15min
checkpoint_completion_target = 0.9
max_wal_size = ${wal}
min_wal_size = 1GB

random_page_cost = ${rpc}
effective_io_concurrency = ${eio}

shared_preload_libraries = 'pg_stat_statements'
pg_stat_statements.track = top
log_min_duration_statement = 500
EOF
  if [[ "$NETWORK_MODE" == public ]]; then
    printf 'log_connections = on\nlog_disconnections = on\n'
  fi
}

step_tuning() {
  local cdir="/etc/postgresql/${PG_VER}/${PG_CLUSTER}" conf tmp need_restart=0
  conf="${cdir}/conf.d/${CONF_NAME}"
  [[ -n "$LISTEN_ADDR" ]] || die "$(L "Внутренняя ошибка: listen_addresses не определён (сначала select_network)" "Internal error: listen_addresses is not defined (run select_network first)")"

  if ! grep -Eq "^[[:space:]]*include_dir[[:space:]]*=[[:space:]]*'conf.d'" "${cdir}/postgresql.conf"; then
    echo "include_dir = 'conf.d'" >> "${cdir}/postgresql.conf"
    log "$(L "В postgresql.conf добавлен include_dir = 'conf.d'" "Added include_dir = 'conf.d' to postgresql.conf")"
  fi
  install -d -o postgres -g postgres -m 755 "${cdir}/conf.d"

  tmp="$(mktemp)"
  render_tuning > "$tmp"
  if [[ -f "$conf" ]] && cmp -s "$tmp" "$conf"; then
    log "$(L "Настройки производительности актуальны ($conf)" "Performance settings are up to date ($conf)")"
  else
    install -o postgres -g postgres -m 644 "$tmp" "$conf"
    log "$(L "Записаны настройки под этот сервер: $conf" "Settings for this server written: $conf")"
    grep -E '^(listen_addresses|max_connections|shared_buffers|effective_cache_size|work_mem|max_parallel_workers|random_page_cost)' "$tmp" | sed 's/^/      /'
    need_restart=1
  fi
  rm -f "$tmp"

  if [[ "$need_restart" == 1 || "$PORT_CHANGED" == 1 ]]; then
    log "$(L "Перезапускаю PostgreSQL для применения настроек" "Restarting PostgreSQL to apply settings")"
    systemctl restart "$SVC"
    if [[ "$PORT_CHANGED" == 1 ]]; then detect_cluster; fi
    wait_ready
  fi
}

step_harden() {
  psql_admin -d postgres -c "REVOKE CONNECT ON DATABASE postgres FROM PUBLIC"
  psql_admin -d postgres -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements" \
    || warn "$(L "pg_stat_statements не создан (проверьте shared_preload_libraries)" "pg_stat_statements was not created (check shared_preload_libraries)")"
  log "$(L "Закрыт публичный CONNECT к служебной БД postgres" "Public CONNECT to the maintenance database postgres closed")"
  if [[ "$(psql_val 'SHOW ssl')" != "on" ]]; then
    warn "$(L "SSL выключен (ssl=off). Подключения по hostssl не заработают — настройте сертификат." "SSL is off (ssl=off). hostssl connections will not work — configure a certificate.")"
  fi
}

step_swap_sysctl() {
  if [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; then
    log "$(L "Swap уже настроен" "Swap is already configured")"
  elif [[ "$SWAP_GB" -gt 0 ]]; then
    if fallocate -l "${SWAP_GB}G" /swapfile 2>/dev/null \
       && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile; then
      grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
      log "$(L "Создан swap ${SWAP_GB} ГБ (страховка от OOM)" "Swap of ${SWAP_GB} GB created (OOM insurance)")"
    else
      warn "$(L "Не удалось создать swap (контейнерная виртуализация?) — пропускаю" "Could not create swap (container virtualization?) — skipping")"
    fi
  fi
  printf 'vm.swappiness = 1\n' > /etc/sysctl.d/99-pgmgr.conf
  sysctl -q -p /etc/sysctl.d/99-pgmgr.conf >/dev/null || warn "$(L "sysctl не применён" "sysctl was not applied")"
}

step_backup() {
  install -d -o postgres -g postgres -m 700 "$BACKUP_DIR"
  {
    cat <<EOF
#!/usr/bin/env bash
# Generated by pg_server_setup.sh — daily logical backup of all databases.
set -Eeuo pipefail
DIR="${BACKUP_DIR}"
KEEP_DAYS="${BACKUP_RETENTION_DAYS}"
export PGPORT="${PG_PORT}"
EOF
    cat <<'EOF'
stamp="$(date +%F_%H%M)"
rc=0
umask 077
while read -r db; do
  [ -n "$db" ] || continue
  if pg_dump -Fc -f "$DIR/${db}_${stamp}.dump.tmp" "$db"; then
    mv "$DIR/${db}_${stamp}.dump.tmp" "$DIR/${db}_${stamp}.dump"
    echo "$(date -Is) OK   $db"
  else
    rm -f "$DIR/${db}_${stamp}.dump.tmp"
    echo "$(date -Is) FAIL $db" >&2
    rc=1
  fi
done < <(psql -X -At -d postgres -c "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres'")
pg_dumpall --globals-only > "$DIR/globals_${stamp}.sql"
find "$DIR" -type f \( -name '*.dump' -o -name 'globals_*.sql' \) -mtime +"$KEEP_DAYS" -delete
exit $rc
EOF
  } > "$BACKUP_BIN"
  chmod 755 "$BACKUP_BIN"
  printf '0 3 * * * postgres %s >> %s/backup.log 2>&1\n' "$BACKUP_BIN" "$BACKUP_DIR" > "$BACKUP_CRON"
  chmod 644 "$BACKUP_CRON"
  log "$(L "Бэкап: ежедневно в 03:00 -> $BACKUP_DIR (хранение ${BACKUP_RETENTION_DAYS} дн.). Копию вне сервера настройте отдельно (rclone/S3)." "Backup: daily at 03:00 -> $BACKUP_DIR (kept ${BACKUP_RETENTION_DAYS} days). Set up an off-server copy separately (rclone/S3).")"
}

cmd_firewall_init() {
  ensure_running
  local sshp
  sshp="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"
  sshp="${sshp:-22}"
  warn "$(L "Будет включён ufw: deny incoming; разрешён SSH (порт $sshp, с ограничением частоты). Порт $PG_PORT — только для клиентов из выбранного режима сети и из access-add." "ufw will be enabled: deny incoming; SSH allowed (port $sshp, rate-limited). Port $PG_PORT — only for clients of the selected network mode and from access-add.")"
  confirm "$(L "Включить файрвол?" "Enable the firewall?")" || { log "$(L "Пропущено" "Skipped")"; return 0; }
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw
  ufw limit "${sshp}/tcp" >/dev/null
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw --force enable >/dev/null
  log "$(L "ufw включён (SSH:$sshp)" "ufw enabled (SSH:$sshp)")"
  apply_ufw_defaults
}

cmd_analyze() {
  analyze_hardware
  resolve_server_role
  print_hw_report
}

cmd_setup() {
  require_root
  cmd_analyze

  detect_cluster
  if [[ -n "$PG_VER" ]]; then
    log "$(L "PostgreSQL ${PG_VER} (кластер ${PG_CLUSTER}, порт ${PG_PORT}) уже установлен" "PostgreSQL ${PG_VER} (cluster ${PG_CLUSTER}, port ${PG_PORT}) is already installed")"
  else
    install_postgres
    detect_cluster
    [[ -n "$PG_VER" ]] || die "$(L "Кластер PostgreSQL не найден после установки" "PostgreSQL cluster not found after installation")"
  fi

  systemctl enable postgresql >/dev/null 2>&1 || true
  if systemctl is-active --quiet "$SVC"; then
    log "$(L "Сервис $SVC запущен" "Service $SVC is running")"
  else
    warn "$(L "Сервис $SVC не запущен — запускаю" "Service $SVC is not running — starting it")"
    systemctl start "$SVC"
  fi
  wait_ready

  select_network 0
  select_port 0
  step_port_config
  step_tuning
  step_port_finish
  step_harden
  step_swap_sysctl
  step_backup

  if ! ufw_active; then
    warn "$(L "Файрвол ufw не активен." "The ufw firewall is not active.")"
    if [[ -t 0 && "$ASSUME_YES" != 1 ]]; then
      if confirm "$(L "Настроить ufw сейчас?" "Set up ufw now?")"; then cmd_firewall_init; fi
    fi
  else
    apply_ufw_defaults
  fi

  print_network_summary
  log "$(L "Сервер PostgreSQL настроен." "The PostgreSQL server is set up.")"

  if [[ -t 0 && "$ASSUME_YES" != 1 ]] \
     && [[ "$(psql_val "SELECT count(*) FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres'")" == 0 ]]; then
    if confirm "$(L "Создать первую БД и её владельца сейчас?" "Create the first database and its owner now?")"; then
      cmd_db_create
      return 0
    fi
  fi
  log "$(L "Дальше: $SELF db-create <имя_бд> [владелец] [IP-клиента]" "Next: $SELF db-create <db_name> [owner] [client-ip]")"
}

cmd_network() { # change the network mode (local / private / public) on an installed server
  ensure_running
  cmd_analyze
  select_network 1
  step_tuning
  apply_ufw_defaults
  print_network_summary
}

# ---------------------------------------------------------- database commands ----

cmd_db_create() {
  ensure_running
  local db="${1:-}" owner="${2:-}" cidr="${3:-}" enc
  if [[ -z "$db" ]]; then ask db "$(L "Имя БД (например calculate_db)" "Database name (e.g. myproject_db)")"; fi
  validate_db "$db"
  if [[ -z "$owner" ]]; then ask owner "$(L "Владелец БД" "Database owner")" "${db}_owner"; fi
  validate_user "$owner"
  resolve_cidrs "$cidr"

  create_login_role "$owner"
  if db_exists "$db"; then
    log "$(L "БД '$db' уже существует — проверяю права и группы" "Database '$db' already exists — checking privileges and groups")"
  else
    enc="$(psql_val "SELECT pg_encoding_to_char(encoding) FROM pg_database WHERE datname='template1'")"
    if [[ "$enc" == "UTF8" ]]; then
      psql_admin -d postgres -c "CREATE DATABASE \"$db\" OWNER \"$owner\" ENCODING 'UTF8'"
    else
      warn "$(L "template1 в кодировке $enc — создаю БД из template0 с C.UTF-8" "template1 uses encoding $enc — creating the database from template0 with C.UTF-8")"
      psql_admin -d postgres -c \
        "CREATE DATABASE \"$db\" OWNER \"$owner\" TEMPLATE template0 ENCODING 'UTF8' LC_COLLATE 'C.UTF-8' LC_CTYPE 'C.UTF-8'"
    fi
    log "$(L "Создана БД '$db' (владелец '$owner')" "Database '$db' created (owner '$owner')")"
  fi
  psql_admin -d postgres <<SQL
REVOKE ALL ON DATABASE "$db" FROM PUBLIC;
GRANT ALL ON DATABASE "$db" TO "$owner";
SQL
  psql_admin -d "$db" <<SQL
REVOKE ALL ON SCHEMA public FROM PUBLIC;
ALTER SCHEMA public OWNER TO "$owner";
SQL
  ensure_db_groups "$db"
  apply_access "$db" "$owner" "$RESOLVED_CIDRS"
  show_credentials "$owner" "$db"
}

cmd_db_drop() {
  ensure_running
  local db="${1:-}" owner f
  if [[ -z "$db" ]]; then ask db "$(L "Имя БД для УДАЛЕНИЯ" "Database name to DROP")"; fi
  validate_db "$db"
  db_exists "$db" || die "$(L "БД '$db' не существует" "Database '$db' does not exist")"
  owner="$(db_owner "$db")"
  warn "$(L "БД '$db' (владелец '$owner') будет удалена безвозвратно. Перед этим сохраню финальный дамп." "Database '$db' (owner '$owner') will be dropped permanently. A final dump is saved first.")"
  confirm_typed "$db" || { log "$(L "Отменено" "Cancelled")"; return 0; }

  install -d -o postgres -g postgres -m 700 "$BACKUP_DIR"
  f="${BACKUP_DIR}/${db}_final_$(date +%F_%H%M).dump"
  runuser -u postgres -- pg_dump -Fc -f "$f" "$db"
  log "$(L "Финальный дамп: $f" "Final dump: $f")"

  terminate_db_sessions "$db"
  psql_admin -d postgres -c "DROP DATABASE \"$db\""
  psql_admin -d postgres -c "DROP ROLE IF EXISTS \"${db}_rw\""
  psql_admin -d postgres -c "DROP ROLE IF EXISTS \"${db}_ro\""
  hba_del "$db" '*'
  log "$(L "БД '$db' удалена (группы ${db}_rw/${db}_ro и правила pg_hba тоже)" "Database '$db' dropped (groups ${db}_rw/${db}_ro and pg_hba rules too)")"

  if [[ "$owner" != "postgres" ]] \
     && [[ "$(psql_val "SELECT count(*) FROM pg_database WHERE datdba=(SELECT oid FROM pg_roles WHERE rolname='$owner')")" == 0 ]]; then
    if confirm "$(L "Пользователь '$owner' больше не владеет БД. Удалить и его?" "User '$owner' no longer owns a database. Drop it too?")"; then
      cmd_user_drop "$owner"
    fi
  fi
}

cmd_db_rename() {
  ensure_running
  local old="${1:-}" new="${2:-}" suf f
  if [[ -z "$old" ]]; then ask old "$(L "Текущее имя БД" "Current database name")"; fi
  if [[ -z "$new" ]]; then ask new "$(L "Новое имя БД" "New database name")"; fi
  validate_db "$old"; validate_db "$new"
  db_exists "$old" || die "$(L "БД '$old' не существует" "Database '$old' does not exist")"
  ! db_exists "$new" || die "$(L "БД '$new' уже существует" "Database '$new' already exists")"
  warn "$(L "Активные подключения к '$old' будут разорваны; строки подключения приложений придётся обновить." "Active connections to '$old' will be dropped; applications' connection strings must be updated.")"
  confirm "$(L "Переименовать '$old' -> '$new'?" "Rename '$old' -> '$new'?")" || { log "$(L "Отменено" "Cancelled")"; return 0; }
  terminate_db_sessions "$old"
  psql_admin -d postgres -c "ALTER DATABASE \"$old\" RENAME TO \"$new\""
  for suf in rw ro; do
    if role_exists "${old}_${suf}"; then
      psql_admin -d postgres -c "ALTER ROLE \"${old}_${suf}\" RENAME TO \"${new}_${suf}\""
    fi
  done
  f="$(hba_file)"
  sed -i "/# ${TAG}:${old}:/{s/^hostssl ${old} /hostssl ${new} /;s/# ${TAG}:${old}:/# ${TAG}:${new}:/}" "$f"
  reload_pg
  log "$(L "БД переименована: '$old' -> '$new'" "Database renamed: '$old' -> '$new'")"
}

cmd_db_chown() {
  ensure_running
  local db="${1:-}" u="${2:-}"
  if [[ -z "$db" ]]; then ask db "$(L "Имя БД" "Database name")"; fi
  if [[ -z "$u" ]]; then ask u "$(L "Новый владелец" "New owner")"; fi
  validate_db "$db"; validate_user "$u"
  db_exists "$db" || die "$(L "БД '$db' не существует" "Database '$db' does not exist")"
  if ! role_exists "$u"; then
    confirm "$(L "Пользователя '$u' нет. Создать?" "User '$u' does not exist. Create it?")" || { log "$(L "Отменено" "Cancelled")"; return 0; }
    create_login_role "$u"
    show_credentials "$u" "$db"
  fi
  set_membership "$db" "$u" none
  set_db_owner "$db" "$u"
}

# ---------------------------------------------------------- user commands ----

cmd_user_create() {
  ensure_running
  local u="${1:-}" db="${2:-}" profile="${3:-}" cidr="${4:-}"
  if [[ -z "$u" ]]; then ask u "$(L "Имя пользователя" "User name")"; fi
  validate_user "$u"
  if [[ -z "$db" && -t 0 ]]; then ask db "$(L "БД для доступа (Enter — без доступа)" "Database to grant access to (Enter = none)")" ""; fi
  if [[ -n "$db" ]]; then
    validate_db "$db"
    db_exists "$db" || die "$(L "БД '$db' не существует (создайте: $SELF db-create $db)" "Database '$db' does not exist (create it: $SELF db-create $db)")"
    if [[ -z "$profile" ]]; then ask profile "$(L "Профиль на '$db' (owner / readwrite / readonly)" "Profile on '$db' (owner / readwrite / readonly)")" "readwrite"; fi
    profile="$(normalize_profile "$profile")"
    resolve_cidrs "$cidr"
  fi
  create_login_role "$u"
  if [[ -n "$db" ]]; then
    apply_profile "$db" "$u" "$profile"
    apply_access "$db" "$u" "$RESOLVED_CIDRS"
  fi
  show_credentials "$u" "$db"
}

cmd_user_role() {
  ensure_running
  local u="${1:-}" db="${2:-}" profile="${3:-}"
  if [[ -z "$u" ]]; then ask u "$(L "Пользователь" "User")"; fi
  if [[ -z "$db" ]]; then ask db "$(L "БД" "Database")"; fi
  if [[ -z "$profile" ]]; then ask profile "$(L "Новый профиль (owner / readwrite / readonly / none)" "New profile (owner / readwrite / readonly / none)")" "readwrite"; fi
  validate_user "$u"; validate_db "$db"
  profile="$(normalize_profile "$profile")"
  role_exists "$u" || die "$(L "Пользователь '$u' не существует" "User '$u' does not exist")"
  db_exists "$db" || die "$(L "БД '$db' не существует" "Database '$db' does not exist")"
  apply_profile "$db" "$u" "$profile"
}

cmd_user_passwd() {
  ensure_running
  local u="${1:-}" esc
  if [[ -z "$u" ]]; then ask u "$(L "Пользователь" "User")"; fi
  validate_user "$u"
  role_exists "$u" || die "$(L "Пользователь '$u' не существует" "User '$u' does not exist")"
  choose_password "$u"
  esc="$(sql_lit "$PASSWORD_INPUT")"
  psql_admin -d postgres <<SQL
ALTER ROLE "$u" PASSWORD '$esc';
SQL
  CREATED_PASSWORD="$PASSWORD_INPUT"
  log "$(L "Пароль '$u' изменён" "Password of '$u' changed")"
  show_credentials "$u" ""
}

cmd_user_limit() {
  ensure_running
  local u="${1:-}" n="${2:-}"
  if [[ -z "$u" ]]; then ask u "$(L "Пользователь" "User")"; fi
  if [[ -z "$n" ]]; then ask n "$(L "Лимит одновременных подключений (-1 — без лимита)" "Concurrent connection limit (-1 = unlimited)")" "-1"; fi
  validate_user "$u"
  [[ "$n" =~ ^-?[0-9]+$ ]] || die "$(L "Лимит должен быть целым числом" "The limit must be an integer")"
  role_exists "$u" || die "$(L "Пользователь '$u' не существует" "User '$u' does not exist")"
  psql_admin -d postgres -c "ALTER ROLE \"$u\" CONNECTION LIMIT $n"
  log "$(L "Лимит подключений '$u' = $n" "Connection limit of '$u' = $n")"
}

cmd_user_rename() {
  ensure_running
  local old="${1:-}" new="${2:-}" f
  if [[ -z "$old" ]]; then ask old "$(L "Текущее имя пользователя" "Current user name")"; fi
  if [[ -z "$new" ]]; then ask new "$(L "Новое имя" "New name")"; fi
  validate_user "$old"; validate_user "$new"
  role_exists "$old" || die "$(L "Пользователь '$old' не существует" "User '$old' does not exist")"
  ! role_exists "$new" || die "$(L "Роль '$new' уже существует" "Role '$new' already exists")"
  confirm "$(L "Переименовать '$old' -> '$new'?" "Rename '$old' -> '$new'?")" || { log "$(L "Отменено" "Cancelled")"; return 0; }
  psql_admin -d postgres -c "ALTER ROLE \"$old\" RENAME TO \"$new\""
  f="$(hba_file)"
  sed -i "/# ${TAG}:[a-z0-9_]*:${old}\$/{s/^\(hostssl [a-z0-9_]* \)${old} /\1${new} /;s/:${old}\$/:${new}/}" "$f"
  reload_pg
  log "$(L "Пользователь переименован: '$old' -> '$new' (строки подключения обновите)" "User renamed: '$old' -> '$new' (update connection strings)")"
}

cmd_user_drop() {
  ensure_running
  local u="${1:-}" d owner owned
  if [[ -z "$u" ]]; then ask u "$(L "Пользователь для УДАЛЕНИЯ" "User to DROP")"; fi
  validate_user "$u"
  role_exists "$u" || die "$(L "Пользователь '$u' не существует" "User '$u' does not exist")"
  owned="$(psql_val "SELECT string_agg(datname, ', ') FROM pg_database WHERE datdba=(SELECT oid FROM pg_roles WHERE rolname='$u')")"
  if [[ -n "$owned" ]]; then
    die "$(L "'$u' владеет БД: $owned. Передайте владение (db-chown) или удалите БД (db-drop)." "'$u' owns databases: $owned. Transfer ownership (db-chown) or drop the databases (db-drop).")"
  fi
  warn "$(L "Пользователь '$u' будет удалён." "User '$u' will be dropped.")"
  confirm_typed "$u" || { log "$(L "Отменено" "Cancelled")"; return 0; }
  while read -r d; do
    [[ -n "$d" ]] || continue
    owner="$(db_owner "$d")"
    psql_admin -d "$d" <<SQL
REASSIGN OWNED BY "$u" TO "$owner";
DROP OWNED BY "$u";
SQL
  done < <(psql_val "SELECT datname FROM pg_database WHERE NOT datistemplate")
  psql_admin -d postgres -c "DROP ROLE \"$u\""
  hba_del '*' "$u"
  log "$(L "Пользователь '$u' удалён" "User '$u' dropped")"
}

# ------------------------------------------------------------- access ----

cmd_access_add() {
  ensure_running
  local db="${1:-}" u="${2:-}" cidr="${3:-}" list
  if [[ -z "$db" ]]; then ask db "$(L "БД" "Database")"; fi
  if [[ -z "$u" ]]; then ask u "$(L "Пользователь" "User")"; fi
  if [[ -z "$cidr" ]]; then ask cidr "$(L "IP/CIDR клиентов через запятую (например 203.0.113.10, 198.51.100.0/24)" "Client IPs/CIDRs, comma-separated (e.g. 203.0.113.10, 198.51.100.0/24)")"; fi
  validate_db "$db"; validate_user "$u"
  db_exists "$db" || die "$(L "БД '$db' не существует" "Database '$db' does not exist")"
  role_exists "$u" || die "$(L "Пользователь '$u' не существует" "User '$u' does not exist")"
  list="$(normalize_cidr_list "$cidr")" || exit 1
  if [[ ",$list," == *,0.0.0.0/0,* ]]; then
    warn "$(L "0.0.0.0/0 открывает доступ '$u' к '$db' из всего интернета." "0.0.0.0/0 opens access of '$u' to '$db' from the whole internet.")"
    confirm_typed "$(all_word)" || { log "$(L "Отменено" "Cancelled")"; return 0; }
  fi
  apply_access "$db" "$u" "$list"
}

cmd_access_del() {
  ensure_running
  local db="${1:-}" u="${2:-}"
  if [[ -z "$db" ]]; then ask db "$(L "БД (или *)" "Database (or *)")"; fi
  if [[ -z "$u" ]]; then ask u "$(L "Пользователь (или *)" "User (or *)")"; fi
  if [[ "$db" != "*" ]]; then validate_db "$db"; fi
  if [[ "$u" != "*" ]]; then validate_user "$u"; fi
  hba_del "$db" "$u"
  log "$(L "Правила pg_hba для $db / $u удалены. Правила ufw (если были) проверьте: ufw status numbered" "pg_hba rules for $db / $u removed. Check ufw rules (if any): ufw status numbered")"
}

# ------------------------------------------------------ information ----

cmd_list() {
  ensure_running
  echo "$(L "--- Базы данных ---" "--- Databases ---")"
  psql_admin -d postgres -c "SELECT d.datname AS db, pg_get_userbyid(d.datdba) AS owner, pg_size_pretty(pg_database_size(d.datname)) AS size FROM pg_database d WHERE NOT d.datistemplate ORDER BY 1"
  echo "$(L "--- Пользователи ---" "--- Users ---")"
  psql_admin -d postgres -c "SELECT rolname AS \"user\", rolcanlogin AS login, rolconnlimit AS conn_limit, rolsuper AS super FROM pg_roles WHERE rolname !~ '^pg_' AND rolname !~ '_(rw|ro)\$' ORDER BY 1"
  echo "$(L "--- Профили (пользователь -> БД) ---" "--- Profiles (user -> database) ---")"
  psql_admin -d postgres -c "SELECT m.rolname AS \"user\", regexp_replace(g.rolname, '_(rw|ro)\$', '') AS db, CASE WHEN g.rolname ~ '_rw\$' THEN 'readwrite' ELSE 'readonly' END AS profile FROM pg_auth_members am JOIN pg_roles g ON g.oid = am.roleid JOIN pg_roles m ON m.oid = am.member WHERE g.rolname ~ '_(rw|ro)\$' AND EXISTS (SELECT 1 FROM pg_database d WHERE d.datname = regexp_replace(g.rolname, '_(rw|ro)\$', '')) UNION ALL SELECT pg_get_userbyid(datdba), datname, 'owner' FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres' ORDER BY 2, 1"
  echo "$(L "--- Правила удалённого доступа (pg_hba, управляются скриптом) ---" "--- Remote access rules (pg_hba, managed by the script) ---")"
  grep "# ${TAG}:" "$(hba_file)" || echo "$(L "(нет)" "(none)")"
  print_network_summary
}

cmd_status() {
  detect_cluster
  if [[ -z "$PG_VER" ]]; then
    warn "$(L "PostgreSQL не установлен. Выполните: $SELF setup" "PostgreSQL is not installed. Run: $SELF setup")"
    return 0
  fi
  echo "$(L "--- Сервис ---" "--- Service ---")"
  pg_lsclusters
  if systemctl is-active --quiet "$SVC"; then
    log "$SVC: active"
    psql_admin -d postgres -c "SELECT version()"
    psql_admin -d postgres -c "SELECT current_setting('listen_addresses') AS listen, current_setting('max_connections') AS max_conn, (SELECT count(*) FROM pg_stat_activity) AS connections, current_setting('shared_buffers') AS shared_buffers, current_setting('ssl') AS ssl"
  else
    warn "$(L "$SVC: НЕ запущен" "$SVC: NOT running")"
  fi
  analyze_hardware
  print_hw_report
  print_network_summary
  echo "$(L "--- Последний бэкап ---" "--- Last backup ---")"
  find "$BACKUP_DIR" -name '*.dump' -printf '%TY-%Tm-%Td %TH:%TM  %p\n' 2>/dev/null | sort | tail -n1 || true
  if ufw_active; then echo "$(L "--- ufw: активен ---" "--- ufw: active ---")"; else echo "$(L "--- ufw: не активен ---" "--- ufw: not active ---")"; fi
}

cmd_backup_now() {
  ensure_running
  [[ -x "$BACKUP_BIN" ]] || step_backup
  runuser -u postgres -- "$BACKUP_BIN"
  log "$(L "Бэкап выполнен -> $BACKUP_DIR" "Backup done -> $BACKUP_DIR")"
}

# ------------------------------------------------------------- menu ----

usage() {
  if [[ "${LANG_UI:-}" == en ]]; then
    cat <<EOF
Usage: $(basename "$SELF") [-y] <command> [arguments]

  setup                                  analyse the server, install, network mode, tuning (idempotent)
  analyze                                cores / RAM / disk report
  network                                change network mode: local | private | public (list/all)
  port        [N|default|random]         change the port: 5432, custom or random free
  lang        [en|ru]                    set the message language
  status                                 service, resources and network state
  list                                   databases, users, profiles, access rules

  db-create   [db] [owner] [ip]          create a database + owner + _rw/_ro groups
  db-drop     [db]                       drop a database (with a final dump)
  db-rename   [old] [new]                rename a database
  db-chown    [db] [user]                change the database owner

  user-create [user] [db] [profile] [ip] create a user; profile: owner|readwrite|readonly
  user-role   [user] [db] [profile]      change the profile (owner|readwrite|readonly|none)
  user-passwd [user]                     change the password (own or generated)
  user-limit  [user] [N]                 connection limit (-1 = unlimited)
  user-rename [old] [new]                rename a user
  user-drop   [user]                     drop a user

  access-add  [db] [user] [ip,cidr,...] allow remote access (pg_hba + ufw)
  access-del  [db|*] [user|*]            remove access rules
  backup-now                             run a backup now
  firewall-init                          enable ufw (SSH + deny incoming)
  menu                                   interactive menu (default)

Arguments you do not pass are requested interactively.
EOF
  else
    cat <<EOF
Использование: $(basename "$SELF") [-y] <команда> [аргументы]

  setup                                  анализ сервера, установка, режим сети, тюнинг (идемпотентно)
  analyze                                анализ ядер / RAM / диска
  network                                сменить режим сети: local | private | public (list/all)
  port        [N|default|random]         сменить порт: 5432, свой или случайный свободный
  lang        [en|ru]                    выбрать язык сообщений
  status                                 состояние сервиса, ресурсов и сети
  list                                   БД, пользователи, профили, правила доступа

  db-create   [db] [owner] [ip]          создать БД + владельца + группы _rw/_ro
  db-drop     [db]                       удалить БД (с финальным дампом)
  db-rename   [old] [new]                переименовать БД
  db-chown    [db] [user]                сменить владельца БД

  user-create [user] [db] [профиль] [ip] создать пользователя; профиль: owner|readwrite|readonly
  user-role   [user] [db] [профиль]      изменить профиль (owner|readwrite|readonly|none)
  user-passwd [user]                     сменить пароль (свой или сгенерированный)
  user-limit  [user] [N]                 лимит подключений (-1 — без лимита)
  user-rename [old] [new]                переименовать пользователя
  user-drop   [user]                     удалить пользователя

  access-add  [db] [user] [ip,cidr,...]  разрешить удалённый доступ (pg_hba + ufw)
  access-del  [db|*] [user|*]            убрать правила доступа
  backup-now                             выполнить бэкап сейчас
  firewall-init                          включить ufw (SSH + deny incoming)
  menu                                   интерактивное меню (по умолчанию)

Аргументы, которые не переданы, будут запрошены интерактивно.
EOF
  fi
}

print_menu() {
  if [[ "${LANG_UI:-}" == en ]]; then
    cat <<'EOF'

========== PostgreSQL: administration ==========
  1) Initial setup / re-check (setup)
  2) Status
  3) List databases, users, profiles
  4) Server analysis (cores, RAM, disk)
  5) Change network mode (local / private / public)
  6) Create database
  7) Drop database
  8) Rename database
  9) Change database owner
 10) Create user
 11) Change a user's profile on a database
 12) Change a user's password
 13) Rename user
 14) User connection limit
 15) Drop user
 16) Add IP access
 17) Remove IP access
 18) Backup now
 19) Enable firewall (ufw)
 20) Change PostgreSQL port
 21) Message language (en / ru)
  0) Exit
EOF
  else
    cat <<'EOF'

========== PostgreSQL: администрирование ==========
  1) Первичная настройка / проверка (setup)
  2) Статус
  3) Список БД, пользователей, профилей
  4) Анализ сервера (ядра, RAM, диск)
  5) Сменить режим сети (local / private / public)
  6) Создать БД
  7) Удалить БД
  8) Переименовать БД
  9) Сменить владельца БД
 10) Создать пользователя
 11) Изменить профиль пользователя на БД
 12) Сменить пароль пользователя
 13) Переименовать пользователя
 14) Лимит подключений пользователя
 15) Удалить пользователя
 16) Добавить IP-доступ
 17) Убрать IP-доступ
 18) Бэкап сейчас
 19) Включить файрвол (ufw)
 20) Сменить порт PostgreSQL
 21) Язык сообщений (en / ru)
  0) Выход
EOF
  fi
}

menu() {
  local choice
  while true; do
    print_menu
    read -r -p "$(L "Выбор: " "Choice: ")" choice || return 0
    case "$choice" in
      1) "$SELF" setup || true ;;
      2) "$SELF" status || true ;;
      3) "$SELF" list || true ;;
      4) "$SELF" analyze || true ;;
      5) "$SELF" network || true ;;
      6) "$SELF" db-create || true ;;
      7) "$SELF" db-drop || true ;;
      8) "$SELF" db-rename || true ;;
      9) "$SELF" db-chown || true ;;
      10) "$SELF" user-create || true ;;
      11) "$SELF" user-role || true ;;
      12) "$SELF" user-passwd || true ;;
      13) "$SELF" user-rename || true ;;
      14) "$SELF" user-limit || true ;;
      15) "$SELF" user-drop || true ;;
      16) "$SELF" access-add || true ;;
      17) "$SELF" access-del || true ;;
      18) "$SELF" backup-now || true ;;
      19) "$SELF" firewall-init || true ;;
      20) "$SELF" port || true ;;
      21) "$SELF" lang || true; LANG_UI="$(state_get LANG_UI)"; LANG_UI="${LANG_UI:-$(default_lang)}" ;;
      0|q|Q) return 0 ;;
      *) warn "$(L "Неизвестный пункт" "Unknown item")" ;;
    esac
  done
}

main() {
  cd /
  while [[ "${1:-}" == -* ]]; do
    case "$1" in
      -y|--yes)  ASSUME_YES=1 ;;
      -h|--help)
        if [[ -z "$LANG_UI" ]]; then LANG_UI="$(default_lang)"; fi
        usage; exit 0 ;;
      *) die "Unknown flag / Неизвестный флаг: $1" ;;
    esac
    shift
  done
  local cmd="${1:-menu}"
  if [[ $# -gt 0 ]]; then shift; fi
  require_root
  init_lang
  case "$cmd" in
    menu)          menu ;;
    setup)         cmd_setup "$@" ;;
    analyze)       cmd_analyze "$@" ;;
    network)       cmd_network "$@" ;;
    port)          cmd_port "$@" ;;
    lang)          cmd_lang "$@" ;;
    status)        cmd_status "$@" ;;
    list)          cmd_list "$@" ;;
    db-create)     cmd_db_create "$@" ;;
    db-drop)       cmd_db_drop "$@" ;;
    db-rename)     cmd_db_rename "$@" ;;
    db-chown)      cmd_db_chown "$@" ;;
    user-create)   cmd_user_create "$@" ;;
    user-role)     cmd_user_role "$@" ;;
    user-passwd)   cmd_user_passwd "$@" ;;
    user-limit)    cmd_user_limit "$@" ;;
    user-rename)   cmd_user_rename "$@" ;;
    user-drop)     cmd_user_drop "$@" ;;
    access-add)    cmd_access_add "$@" ;;
    access-del)    cmd_access_del "$@" ;;
    backup-now)    cmd_backup_now "$@" ;;
    firewall-init) cmd_firewall_init "$@" ;;
    help|usage)    usage ;;
    *) usage; die "$(L "Неизвестная команда: $cmd" "Unknown command: $cmd")" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
