#!/usr/bin/env bash
#
# pg_server_setup.sh — первичная настройка и администрирование PostgreSQL
# на выделенном VPS (Ubuntu/Debian). Скрипт идемпотентен: повторный запуск
# `setup` проверяет, что установлено и работает, и донастраивает только
# недостающее.
#
# Что делает `setup`:
#   1. Анализирует сервер (ядра, RAM всего/свободно, диск, swap) и по нему
#      рассчитывает настройки PostgreSQL.
#   2. Спрашивает режим сети:
#        local   — только этот сервер (listen = localhost);
#        private — приватная сеть/VPN (listen = приватный IP + localhost);
#        public  — публичный IP: доступ для ВСЕХ (0.0.0.0/0) либо только
#                  для выбранных IP / диапазонов.
#   3. Спрашивает порт PostgreSQL: стандартный 5432, свой или случайный
#      свободный (можно сменить позже командой `port`).
#   4. Ставит PostgreSQL (PGDG), тюнит, закрывает лишнее, настраивает swap,
#      бэкапы и (по желанию) файрвол ufw.
#
# Модель изоляции: один кластер, на каждый проект — своя БД.
#   * <db>_owner  — владелец БД (DDL: создаёт/меняет таблицы, миграции);
#   * <db>_rw     — группа NOLOGIN: SELECT/INSERT/UPDATE/DELETE;
#   * <db>_ro     — группа NOLOGIN: только SELECT.
# Профиль пользователя на БД = членство в группе (owner | readwrite | readonly).
# У PUBLIC отозваны CONNECT и права на схему public, поэтому пользователь
# одного проекта не видит и не читает БД другого. Схема — только public.
#
# Запуск (от root):
#   ./pg_server_setup.sh                  # интерактивное меню
#   ./pg_server_setup.sh setup            # первичная настройка / повторная проверка
#   ./pg_server_setup.sh -y <команда> ... # -y: без подтверждений (для автоматизации)
#   ./pg_server_setup.sh help             # список команд
#
# Переменные окружения (необязательные; для неинтерактивного запуска):
#   NETWORK_MODE=local|private|public   ACCESS_POLICY=list|all (для public)
#   LISTEN_ADDR=10.0.0.5[,IP2] | '*'    ALLOWED_CIDR=203.0.113.10,198.51.100.0/24
#   DB_PORT=default|random|<число>      SERVER_ROLE=dedicated|shared
#   PG_VERSION=17
#   MAX_CONNECTIONS=<N>  STORAGE=ssd|hdd  SWAP_GB=2
#   BACKUP_DIR=/var/backups/postgresql  BACKUP_RETENTION_DAYS=14
#   PGMGR_PASSWORD=...   (готовый пароль для создаваемого/меняемого пользователя)

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
MAX_CONNECTIONS="${MAX_CONNECTIONS:-}"      # пусто = авторасчёт по ресурсам
STORAGE="${STORAGE:-}"                       # пусто = автоопределение
SWAP_GB="${SWAP_GB:-2}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/postgresql}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
ASSUME_YES=0

PG_VER=""
PG_CLUSTER="main"
PG_PORT="5432"
SVC=""
PASSWORD_INPUT=""
CREATED_PASSWORD=""
PASSWORD_GENERATED=0
RESOLVED_CIDRS=""

# Итоги анализа сервера (analyze_hardware)
HW_CORES=1; HW_MEM_MB=0; HW_AVAIL_MB=0; HW_SWAP_MB=0
HW_DISK_FREE_GB=0; HW_DISK_TOTAL_GB=0; HW_DISK_PATH="/"
HW_STORAGE_DETECTED="unknown"; HW_VIRT="unknown"

# Итоги выбора сети (select_network)
NETWORK_MODE="${NETWORK_MODE:-}"
ACCESS_POLICY="${ACCESS_POLICY:-}"
DEFAULT_CIDRS=""
LISTEN_ADDR="${LISTEN_ADDR:-}"
SERVER_ROLE="${SERVER_ROLE:-}"
IP_CANDS=()

# Выбор порта (select_port / step_port_config)
DB_PORT="${DB_PORT:-}"
DESIRED_PORT=""
PORT_OLD=""
PORT_CHANGED=0

# ---------------------------------------------------------------- вывод ----

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

trap 'warn "Сбой на строке ${LINENO} (команда: ${BASH_COMMAND})"' ERR

require_root() {
  [[ $EUID -eq 0 ]] || die "Запустите от root: sudo $SELF"
}

ask() { # ask VAR "вопрос" [значение_по_умолчанию]
  local __var="$1" __prompt="$2" __def="${3:-}" __ans=""
  [[ -t 0 ]] || die "Не хватает аргумента: $__prompt (нет интерактивного ввода)"
  read -r -p "${__prompt}${__def:+ [$__def]}: " __ans || die "Ввод прерван"
  printf -v "$__var" '%s' "${__ans:-$__def}"
}

pick() { # pick VAR "заголовок" номер_по_умолчанию вариант1 вариант2 ... -> VAR = номер
  local __var="$1" __title="$2" __def="$3" __i=1 __o __pa=""
  shift 3
  echo "$__title"
  for __o in "$@"; do
    printf '  %d) %s\n' "$__i" "$__o"
    __i=$(( __i + 1 ))
  done
  while true; do
    ask __pa "Выбор" "$__def"
    if [[ "$__pa" =~ ^[0-9]+$ ]] && (( __pa >= 1 && __pa <= $# )); then
      printf -v "$__var" '%s' "$__pa"
      return 0
    fi
    warn "Введите число от 1 до $#"
  done
}

confirm() {
  if [[ "$ASSUME_YES" == 1 ]]; then return 0; fi
  local a=""
  [[ -t 0 ]] || die "Нужно подтверждение, но нет интерактивного ввода (используйте -y)"
  read -r -p "$1 [y/N] " a || return 1
  [[ "$a" =~ ^[YyДд] ]]
}

confirm_typed() { # требует ввести слово/имя целиком
  if [[ "$ASSUME_YES" == 1 ]]; then return 0; fi
  local a=""
  [[ -t 0 ]] || die "Нужно подтверждение, но нет интерактивного ввода (используйте -y)"
  read -r -p "Для подтверждения введите '$1': " a || return 1
  [[ "$a" == "$1" ]]
}

gb() { awk -v m="$1" 'BEGIN{printf "%.1f", m/1024}'; }

# ------------------------------------------------------------ валидация ----

validate_db() {
  [[ "$1" =~ ^[a-z_][a-z0-9_]{0,59}$ ]] \
    || die "Недопустимое имя БД '$1' (a-z, 0-9, _; начинается с буквы/_; до 60 символов)"
}

validate_user() {
  [[ "$1" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] \
    || die "Недопустимое имя пользователя '$1' (a-z, 0-9, _; до 63 символов)"
}

normalize_profile() { # -> owner|readwrite|readonly|none
  case "${1,,}" in
    owner|o)                echo owner ;;
    readwrite|rw|write)     echo readwrite ;;
    readonly|ro|read)       echo readonly ;;
    none|no|-|"")           echo none ;;
    *) die "Неизвестный профиль '$1' (owner | readwrite | readonly | none)" ;;
  esac
}

normalize_cidr() { # IPv4[/маска] -> IPv4/маска
  local c="$1" ip mask="32" o
  local -a oct
  [[ "$c" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] || die "Некорректный IPv4/CIDR: '$c'"
  ip="${c%%/*}"
  if [[ "$c" == */* ]]; then mask="${c##*/}"; fi
  IFS=. read -ra oct <<<"$ip"
  for o in "${oct[@]}"; do
    (( 10#$o <= 255 )) || die "Некорректный октет в '$c'"
  done
  (( 10#$mask <= 32 )) || die "Некорректная маска в '$c'"
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
    [[ "$it" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Некорректный адрес прослушивания: '$it'"
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

is_private_ip() { # RFC1918 + CGNAT 100.64/10 (Tailscale и т.п.)
  local a b
  IFS=. read -r a b _ <<<"$1"
  (( a == 10 )) || (( a == 172 && b >= 16 && b <= 31 )) \
    || (( a == 192 && b == 168 )) || (( a == 100 && b >= 64 && b <= 127 ))
}

# -------------------------------------------- состояние (/etc/pgmgr) ----

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

# --------------------------------------------------- кластер и сервис ----

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
  die "PostgreSQL не отвечает после 30 секунд ожидания (journalctl -u $SVC)"
}

ensure_running() {
  detect_cluster
  [[ -n "$PG_VER" ]] || die "PostgreSQL не установлен. Сначала выполните: $SELF setup"
  if ! systemctl is-active --quiet "$SVC"; then
    warn "PostgreSQL ($SVC) не запущен — запускаю"
    systemctl start "$SVC"
  fi
  wait_ready
}

# ------------------------------------------------- анализ ресурсов сервера ----

detect_storage() { # ssd | hdd | unknown (по данным ядра; на VPS бывает неточно)
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
    # На VPS virtio-диски часто ложно помечены как HDD — считаем HDD только на «железе».
    if [[ "$HW_STORAGE_DETECTED" == hdd && "$HW_VIRT" == none ]]; then STORAGE=hdd; else STORAGE=ssd; fi
  fi
}

resolve_server_role() { # dedicated | shared
  local r="${SERVER_ROLE:-}"
  if [[ -z "$r" ]]; then r="$(state_get SERVER_ROLE)"; fi
  if [[ -z "$r" ]]; then
    r=dedicated
    if (( HW_AVAIL_MB * 100 < HW_MEM_MB * 60 )) && [[ -t 0 && "$ASSUME_YES" != 1 ]]; then
      warn "Свободно $(gb "$HW_AVAIL_MB") ГБ из $(gb "$HW_MEM_MB") ГБ — часть памяти занята другими процессами."
      confirm "Сервер выделен под PostgreSQL (использовать всю RAM в расчётах)?" || r=shared
    fi
  fi
  case "$r" in
    dedicated|shared) ;;
    *) die "SERVER_ROLE должен быть dedicated или shared" ;;
  esac
  SERVER_ROLE="$r"
  state_set SERVER_ROLE "$r"
}

print_hw_report() {
  local used=$(( HW_MEM_MB - HW_AVAIL_MB ))
  echo "--- Анализ сервера ---"
  printf '  CPU:            %s ядер\n' "$HW_CORES"
  printf '  RAM:            %s ГБ всего, %s ГБ свободно (занято сейчас: %s ГБ)\n' \
    "$(gb "$HW_MEM_MB")" "$(gb "$HW_AVAIL_MB")" "$(gb "$used")"
  printf '  Swap:           %s ГБ\n' "$(gb "$HW_SWAP_MB")"
  printf '  Диск (%s): %s ГБ свободно из %s ГБ\n' "$HW_DISK_PATH" "$HW_DISK_FREE_GB" "$HW_DISK_TOTAL_GB"
  printf '  Тип диска:      %s (ядро сообщает: %s; виртуализация: %s)\n' "$STORAGE" "$HW_STORAGE_DETECTED" "$HW_VIRT"
  if (( HW_CORES < 2 )); then warn "1 ядро: параллельные запросы и автовакуум будут ограничены"; fi
  if (( HW_MEM_MB < 2000 )); then warn "RAM меньше 2 ГБ: PostgreSQL будет работать, но на пределе"; fi
  if (( HW_DISK_FREE_GB < 10 )); then warn "Свободно менее 10 ГБ на диске данных"; fi
  if (( HW_AVAIL_MB * 100 < HW_MEM_MB * 50 )); then
    warn "Больше половины RAM занято другими процессами — для БД лучше выделенный сервер"
  fi
}

# ------------------------------------------------- pg_hba.conf и файрвол ----

hba_file() { psql_val "SHOW hba_file"; }

hba_drop_line() { # hba_drop_line файл "точная строка"
  local f="$1" line="$2"
  grep -vxF -- "$line" "$f" > "$f.pgmgr.tmp" || true
  cat "$f.pgmgr.tmp" > "$f"
  rm -f "$f.pgmgr.tmp"
}

ufw_active() { command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; }

ufw_allow() { # cidr; 0.0.0.0/0 = отовсюду
  if ufw_active; then
    if [[ "$1" == "0.0.0.0/0" ]]; then
      ufw allow "${PG_PORT}/tcp" >/dev/null
      log "ufw: разрешён ${PG_PORT}/tcp отовсюду"
    else
      ufw allow from "$1" to any port "$PG_PORT" proto tcp >/dev/null
      log "ufw: разрешён $1 -> ${PG_PORT}/tcp"
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
    log "Правило pg_hba уже есть: $db / $u / $cidr"
  else
    if [[ -n "$(tail -c1 "$f")" ]]; then echo >> "$f"; fi
    printf '%s\n' "$line" >> "$f"
    errs="$(psql_val "SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL")"
    if [[ "$errs" != 0 ]]; then
      hba_drop_line "$f" "$line"
      die "pg_hba.conf стал некорректным — правило откатено"
    fi
    reload_pg
    log "pg_hba: разрешён $u к $db с $cidr (hostssl, scram-sha-256)"
  fi
  if [[ "$(psql_val 'SHOW listen_addresses')" == "localhost" ]]; then
    warn "listen_addresses=localhost — удалённые подключения не заработают. Смените режим сети: $SELF network"
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

# Откуда пускать нового пользователя/БД: аргумент -> иначе значение по режиму сети.
# Результат в RESOLVED_CIDRS (через запятую, может быть пустым = только локально).
resolve_cidrs() {
  local arg="${1:-}" def mode
  RESOLVED_CIDRS=""
  mode="$(state_get NETWORK_MODE)"
  def="$(state_get DEFAULT_CIDRS)"
  def="${def:-${ALLOWED_CIDR:-}}"
  if [[ -z "$arg" ]]; then
    if [[ "${mode:-local}" == local && -z "$def" ]]; then return 0; fi
    if [[ -t 0 && "$ASSUME_YES" != 1 ]]; then
      ask arg "Откуда разрешён доступ (IP/CIDR через запятую, '-' — только локально)" "${def:--}"
    else
      arg="$def"
    fi
  fi
  case "$arg" in
    -|none|"") return 0 ;;
  esac
  RESOLVED_CIDRS="$(normalize_cidr_list "$arg")" || exit 1
}

hba_del() { # hba_del db user  (db/user = '*' -> любые)
  local db="$1" u="$2" f pat
  f="$(hba_file)"
  if [[ "$db" == "*" ]]; then db='[a-z0-9_]*'; fi
  if [[ "$u" == "*" ]]; then u='[a-z0-9_]*'; fi
  pat="# ${TAG}:${db}:${u}\$"
  cp -n "$f" "$f.pgmgr.orig" || true
  sed -i "/${pat}/d" "$f"
  reload_pg
}

# ------------------------------------------------------- режим сети ----

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
    log "Сеть (из сохранённых настроек): ${NETWORK_MODE}, listen=${LISTEN_ADDR}, доступ=${ACCESS_POLICY:-none} ${DEFAULT_CIDRS}"
    return 0
  fi

  if [[ -z "$mode" ]]; then
    if [[ -t 0 ]]; then
      case "$saved_mode" in private) def_idx=2 ;; public) def_idx=3 ;; esac
      pick idx "Режим доступа к PostgreSQL:" "$def_idx" \
        "local   — только этот сервер (localhost): приложения работают на самом VPS" \
        "private — приватная сеть / VPN (WireGuard, Tailscale, VPC): слушать приватный IP" \
        "public  — публичный IP: доступ для ВСЕХ или только для выбранных IP/диапазонов"
      case "$idx" in 1) mode=local ;; 2) mode=private ;; 3) mode=public ;; esac
    else
      mode=local
      warn "Режим сети не задан (нет интерактива и NETWORK_MODE) — использую local"
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
          pick idx "Приватные адреса этого сервера:" 1 "${IP_CANDS[@]}"
          net="${IP_CANDS[idx-1]}"
        else
          net="${IP_CANDS[0]}"
        fi
        listen_val="$(ip_of "$net")"
        if [[ -z "$cidrs" ]]; then cidrs="$(cidr_network "$(awk '{print $2}' <<<"$net")")"; fi
      else
        [[ -t 0 ]] || die "Приватный IP не найден: задайте LISTEN_ADDR"
        warn "Приватных адресов (10.x/172.16-31.x/192.168.x/100.64.x) не найдено. Создайте приватную сеть/VPN или укажите IP вручную."
        ask listen_val "Приватный IP для прослушивания"
      fi
      policy="list"
      if [[ -t 0 && "$ASSUME_YES" != 1 ]]; then
        ask cidrs "Кому разрешить доступ (сети/IP клиентов, через запятую)" "$cidrs"
      fi
      [[ -n "$cidrs" ]] || die "Не задан список разрешённых клиентов (ALLOWED_CIDR)"
      ;;
    public)
      collect_ips public
      if [[ -n "$listen_in" ]]; then
        listen_val="$listen_in"
      else
        opts=("${IP_CANDS[@]}" "* — все интерфейсы (сервер за NAT или несколько IP)")
        if [[ -t 0 ]]; then
          pick idx "Публичные адреса этого сервера (на каком слушать):" 1 "${opts[@]}"
          if (( idx == ${#opts[@]} )); then listen_val='*'; else listen_val="$(ip_of "${IP_CANDS[idx-1]}")"; fi
        elif (( ${#IP_CANDS[@]} > 0 )); then
          listen_val="$(ip_of "${IP_CANDS[0]}")"
        else
          listen_val='*'
        fi
      fi
      if [[ -z "$policy" ]]; then
        if [[ -t 0 ]]; then
          pick idx "Кто может подключаться:" 1 \
            "Только определённые IP / диапазоны (рекомендуется)" \
            "Все (0.0.0.0/0) — защита только паролем + SSL, открыто всему интернету"
          if (( idx == 1 )); then policy=list; else policy=all; fi
        else
          die "Для public задайте ACCESS_POLICY=list|all"
        fi
      fi
      case "$policy" in
        list)
          if [[ -z "$cidrs" ]]; then
            [[ -t 0 ]] || die "Для ACCESS_POLICY=list задайте ALLOWED_CIDR"
            while [[ -z "$cidrs" ]]; do
              ask cidrs "Разрешённые IP/диапазоны (например 203.0.113.10, 198.51.100.0/24)"
            done
          fi
          ;;
        all)
          warn "Порт PostgreSQL будет доступен всему интернету. Защита: scram-sha-256, SSL, правила по БД/пользователю — но брутфорс возможен."
          confirm_typed "ВСЕМ" || die "Отменено"
          cidrs="0.0.0.0/0"
          ;;
        *) die "ACCESS_POLICY должен быть list или all" ;;
      esac
      ;;
    *) die "NETWORK_MODE должен быть local, private или public" ;;
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
  log "Сеть: режим=${mode}, listen=${final}, доступ=${policy} ${cidrs}"
  if [[ -n "$saved_mode" && ( "$saved_mode" != "$mode" || "$saved_policy" != "$policy" ) ]]; then
    warn "Режим изменён. Старые правила pg_hba могли остаться — проверьте: $SELF list"
  fi
}

apply_ufw_defaults() { # порт PG — только для клиентов из выбранного режима сети
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
    warn "ufw не активен: порт ${PG_PORT} защищён только pg_hba.conf. Рекомендуется: $SELF firewall-init"
  fi
}

# ------------------------------------------------------------- порт ----

port_in_use() { [[ -n "$(ss -H -ltn "sport = :$1" 2>/dev/null)" ]]; }

ssh_port() {
  local p
  p="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"
  echo "${p:-22}"
}

validate_port() { # порт должен быть числом 1024-65535, не SSH и не занят чужим процессом
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || die "Порт должен быть числом: '$p'"
  (( p >= 1024 && p <= 65535 )) || die "Порт вне диапазона 1024-65535: $p"
  if [[ "$p" == "$(ssh_port)" ]]; then die "Порт $p занят под SSH"; fi
  if [[ "$p" != "$PG_PORT" ]] && port_in_use "$p"; then die "Порт $p уже занят другим процессом"; fi
}

random_free_port() {
  local i p
  for i in $(seq 1 50); do
    p="$(shuf -i 10000-32000 -n1)"
    if [[ "$p" != "$(ssh_port)" ]] && ! port_in_use "$p"; then echo "$p"; return 0; fi
  done
  die "Не удалось подобрать свободный порт"
}

# Выбор порта: стандартный 5432 / свой / случайный свободный. Ничего не меняет,
# только определяет DESIRED_PORT. Сохранённый выбор повторно не спрашивается.
select_port() { # select_port [force=0]
  local force="${1:-0}" choice="${DB_PORT:-}" saved idx=1
  saved="$(state_get DB_PORT)"

  if [[ -z "$choice" && -n "$saved" && "$force" != 1 ]]; then
    DESIRED_PORT="$saved"
    log "Порт (из сохранённых настроек): $DESIRED_PORT"
    return 0
  fi

  if [[ -z "$choice" ]]; then
    if [[ -t 0 ]]; then
      pick idx "Порт PostgreSQL (сейчас: ${PG_PORT}):" 1 \
        "Стандартный 5432" \
        "Свой порт" \
        "Случайный свободный порт"
      case "$idx" in
        1) choice=default ;;
        2) ask choice "Введите порт (1024-65535)" ;;
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
  log "Выбран порт PostgreSQL: $DESIRED_PORT"
}

# Прописывает порт в postgresql.conf кластера (pg_conftool). Перезапуск выполняет вызывающий.
step_port_config() {
  PORT_CHANGED=0
  if [[ "$DESIRED_PORT" == "$PG_PORT" ]]; then
    log "Порт PostgreSQL: $PG_PORT"
    state_set DB_PORT "$PG_PORT"
    return 0
  fi
  PORT_OLD="$PG_PORT"
  pg_conftool "$PG_VER" "$PG_CLUSTER" set port "$DESIRED_PORT"
  PORT_CHANGED=1
  log "Порт в конфигурации: $PORT_OLD -> $DESIRED_PORT (применится после перезапуска)"
}

managed_cidrs() { # CIDR из правил pg_hba скрипта + сети режима
  local f
  f="$(hba_file)"
  { grep "# ${TAG}:" "$f" || true; } | awk '{print $4}'
  state_get DEFAULT_CIDRS | tr ',' '\n'
}

migrate_ufw_port() { # migrate_ufw_port старый новый
  local old="$1" new="$2" c
  if ! ufw_active; then
    if [[ "$(state_get NETWORK_MODE)" == public ]]; then
      warn "ufw не активен: порт $new защищён только pg_hba.conf. Рекомендуется: $SELF firewall-init"
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
  log "ufw: правила перенесены с порта $old на $new"
}

# Вызывать после перезапуска PostgreSQL и detect_cluster с новым портом.
step_port_finish() {
  if [[ "$PORT_CHANGED" != 1 ]]; then return 0; fi
  if [[ "$(psql_val 'SHOW port')" != "$DESIRED_PORT" ]]; then
    die "PostgreSQL слушает не порт $DESIRED_PORT (проверьте conf.d и journalctl -u $SVC)"
  fi
  state_set DB_PORT "$DESIRED_PORT"
  migrate_ufw_port "$PORT_OLD" "$DESIRED_PORT"
  PORT_CHANGED=0
  warn "Порт изменён: $PORT_OLD -> $DESIRED_PORT. Обновите строки подключения приложений; локально: psql -p $DESIRED_PORT"
}

cmd_port() { # cmd_port [порт|default|random]
  ensure_running
  local arg="${1:-}"
  if [[ -n "$arg" ]]; then DB_PORT="$arg"; fi
  select_port 1
  step_port_config
  if [[ "$PORT_CHANGED" == 1 ]]; then
    warn "PostgreSQL будет перезапущен, активные подключения оборвутся."
    confirm "Сменить порт $PORT_OLD -> $DESIRED_PORT?" || {
      pg_conftool "$PG_VER" "$PG_CLUSTER" set port "$PORT_OLD"; PORT_CHANGED=0; log "Отменено"; return 0; }
    systemctl restart "$SVC"
    detect_cluster
    wait_ready
    step_port_finish
    if [[ -x "$BACKUP_BIN" ]]; then step_backup; fi
  fi
}

print_network_summary() {
  echo "--- Сеть ---"
  printf '  Режим:          %s\n' "$(state_get NETWORK_MODE)"
  printf '  listen:         %s (порт %s)\n' "$(state_get LISTEN_ADDR)" "$PG_PORT"
  printf '  Политика:       %s\n' "$(state_get ACCESS_POLICY)"
  printf '  Клиенты:        %s\n' "$(state_get DEFAULT_CIDRS)"
  if [[ "$(state_get NETWORK_MODE)" == public ]]; then
    echo "  SSL:            сертификат по умолчанию самоподписанный: шифрует, но не подтверждает сервер."
    echo "                  Для sslmode=verify-full установите свой сертификат (например Let's Encrypt)."
  fi
}

# -------------------------------------------- роли, группы, владельцы ----

# Выбор пароля: ввести свой или сгенерировать. -> PASSWORD_INPUT, PASSWORD_GENERATED
choose_password() { # choose_password "для кого"
  local who="$1" mode=1 p1 p2
  PASSWORD_GENERATED=0
  if [[ -n "${PGMGR_PASSWORD:-}" ]]; then
    PASSWORD_INPUT="$PGMGR_PASSWORD"
    (( ${#PASSWORD_INPUT} >= MIN_PASSWORD_LEN )) || die "Пароль короче ${MIN_PASSWORD_LEN} символов"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    PASSWORD_INPUT="$(gen_password)"; PASSWORD_GENERATED=1
    return 0
  fi
  pick mode "Пароль для '$who':" 1 \
    "Сгенерировать надёжный случайный (рекомендуется)" \
    "Ввести свой"
  if (( mode == 1 )); then
    PASSWORD_INPUT="$(gen_password)"; PASSWORD_GENERATED=1
    return 0
  fi
  while true; do
    read -rs -p "Введите пароль (минимум ${MIN_PASSWORD_LEN} символов): " p1 || die "Ввод прерван"; echo
    if (( ${#p1} < MIN_PASSWORD_LEN )); then warn "Слишком короткий пароль"; continue; fi
    read -rs -p "Повторите пароль: " p2 || die "Ввод прерван"; echo
    if [[ "$p1" != "$p2" ]]; then warn "Пароли не совпадают"; continue; fi
    PASSWORD_INPUT="$p1"
    if [[ "$p1" =~ [@:/?#%\ ] ]]; then
      warn "В пароле есть спецсимволы (@ : / ? # % пробел) — в URL-строке подключения их нужно кодировать (percent-encoding)."
    fi
    return 0
  done
}

create_login_role() { # -> CREATED_PASSWORD (пусто, если роль уже была)
  local u="$1" esc
  CREATED_PASSWORD=""
  if role_exists "$u"; then
    log "Пользователь '$u' уже существует — пароль не меняю"
    return 0
  fi
  choose_password "$u"
  esc="$(sql_lit "$PASSWORD_INPUT")"
  psql_admin -d postgres <<SQL
CREATE ROLE "$u" LOGIN PASSWORD '$esc' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
SQL
  CREATED_PASSWORD="$PASSWORD_INPUT"
  log "Создан пользователь '$u'"
}

show_credentials() { # user db
  [[ -n "$CREATED_PASSWORD" ]] || return 0
  echo
  echo "=============== Учётные данные (показываются один раз) ==============="
  echo "  Пользователь: $1"
  if [[ "$PASSWORD_GENERATED" == 1 ]]; then
    echo "  Пароль:       $CREATED_PASSWORD"
  else
    echo "  Пароль:       (задан вами)"
  fi
  if [[ -n "${2:-}" ]]; then
    echo "  DSN:          postgresql://$1:<пароль>@<HOST>:${PG_PORT}/$2?sslmode=require"
  fi
  echo "======================================================================"
  echo
}

# Создаёт (идемпотентно) группы <db>_rw / <db>_ro и настраивает их права,
# включая DEFAULT PRIVILEGES для будущих таблиц владельца БД.
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
  if [[ "$old" == "$u" ]]; then log "'$u' уже владелец '$db'"; return 0; fi
  terminate_db_sessions "$db"
  psql_admin -d postgres -c "ALTER DATABASE \"$db\" OWNER TO \"$u\""
  psql_admin -d "$db" -c "ALTER SCHEMA public OWNER TO \"$u\""
  if [[ "$old" != "postgres" ]]; then
    others="$(psql_val "SELECT count(*) FROM pg_database WHERE datdba=(SELECT oid FROM pg_roles WHERE rolname='$old')")"
    if [[ "$others" == 0 ]]; then
      psql_admin -d "$db" -c "REASSIGN OWNED BY \"$old\" TO \"$u\""
    else
      warn "'$old' владеет и другими БД — объекты внутри '$db' остались за ним (REASSIGN не выполнялся)"
    fi
  fi
  ensure_db_groups "$db"
  log "Владелец '$db' теперь '$u'"
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
        die "'$u' — владелец '$db'. Сначала передайте владение: $SELF db-chown $db <другой_пользователь>"
      fi
      set_membership "$db" "$u" "$p"
      log "'$u' -> '$db': $p"
      ;;
    none)
      if [[ "$(db_owner "$db")" == "$u" ]]; then
        die "'$u' — владелец '$db'. Сначала передайте владение: $SELF db-chown $db <другой_пользователь>"
      fi
      set_membership "$db" "$u" none
      log "У '$u' отозван доступ к '$db'"
      ;;
  esac
}

# ------------------------------------------------------------ setup ----

install_postgres() {
  export DEBIAN_FRONTEND=noninteractive
  log "Устанавливаю PostgreSQL ${PG_VERSION} из репозитория PGDG"
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates gnupg lsb-release openssl postgresql-common
  /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
  apt-get install -y -qq "postgresql-${PG_VERSION}"
}

# Расчёт параметров под конкретный сервер (ядра, RAM, тип диска, роль, сеть).
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
# Управляется pg_server_setup.sh — вручную не править (перезаписывается при setup).
# CPU: ${HW_CORES} ядер, RAM: ${HW_MEM_MB} МБ (бюджет ${budget} МБ, роль: ${SERVER_ROLE}), диск: ${STORAGE}
# Сеть: ${NETWORK_MODE}
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
  [[ -n "$LISTEN_ADDR" ]] || die "Внутренняя ошибка: listen_addresses не определён (сначала select_network)"

  if ! grep -Eq "^[[:space:]]*include_dir[[:space:]]*=[[:space:]]*'conf.d'" "${cdir}/postgresql.conf"; then
    echo "include_dir = 'conf.d'" >> "${cdir}/postgresql.conf"
    log "В postgresql.conf добавлен include_dir = 'conf.d'"
  fi
  install -d -o postgres -g postgres -m 755 "${cdir}/conf.d"

  tmp="$(mktemp)"
  render_tuning > "$tmp"
  if [[ -f "$conf" ]] && cmp -s "$tmp" "$conf"; then
    log "Настройки производительности актуальны ($conf)"
  else
    install -o postgres -g postgres -m 644 "$tmp" "$conf"
    log "Записаны настройки под этот сервер: $conf"
    grep -E '^(listen_addresses|max_connections|shared_buffers|effective_cache_size|work_mem|max_parallel_workers|random_page_cost)' "$tmp" | sed 's/^/      /'
    need_restart=1
  fi
  rm -f "$tmp"

  if [[ "$need_restart" == 1 || "$PORT_CHANGED" == 1 ]]; then
    log "Перезапускаю PostgreSQL для применения настроек"
    systemctl restart "$SVC"
    if [[ "$PORT_CHANGED" == 1 ]]; then detect_cluster; fi
    wait_ready
  fi
}

step_harden() {
  psql_admin -d postgres -c "REVOKE CONNECT ON DATABASE postgres FROM PUBLIC"
  psql_admin -d postgres -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements" \
    || warn "pg_stat_statements не создан (проверьте shared_preload_libraries)"
  log "Закрыт публичный CONNECT к служебной БД postgres"
  if [[ "$(psql_val 'SHOW ssl')" != "on" ]]; then
    warn "SSL выключен (ssl=off). Подключения по hostssl не заработают — настройте сертификат."
  fi
}

step_swap_sysctl() {
  if [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; then
    log "Swap уже настроен"
  elif [[ "$SWAP_GB" -gt 0 ]]; then
    if fallocate -l "${SWAP_GB}G" /swapfile 2>/dev/null \
       && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile; then
      grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
      log "Создан swap ${SWAP_GB} ГБ (страховка от OOM)"
    else
      warn "Не удалось создать swap (контейнерная виртуализация?) — пропускаю"
    fi
  fi
  printf 'vm.swappiness = 1\n' > /etc/sysctl.d/99-pgmgr.conf
  sysctl -q -p /etc/sysctl.d/99-pgmgr.conf >/dev/null || warn "sysctl не применён"
}

step_backup() {
  install -d -o postgres -g postgres -m 700 "$BACKUP_DIR"
  {
    cat <<EOF
#!/usr/bin/env bash
# Сгенерировано pg_server_setup.sh — ежедневный логический бэкап всех БД.
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
  log "Бэкап: ежедневно в 03:00 -> $BACKUP_DIR (хранение ${BACKUP_RETENTION_DAYS} дн.). Копию вне сервера настройте отдельно (rclone/S3)."
}

cmd_firewall_init() {
  ensure_running
  local sshp
  sshp="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"
  sshp="${sshp:-22}"
  warn "Будет включён ufw: deny incoming; разрешён SSH (порт $sshp, с ограничением частоты). Порт $PG_PORT — только для клиентов из выбранного режима сети и из access-add."
  confirm "Включить файрвол?" || { log "Пропущено"; return 0; }
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw
  ufw limit "${sshp}/tcp" >/dev/null
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw --force enable >/dev/null
  log "ufw включён (SSH:$sshp)"
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
    log "PostgreSQL ${PG_VER} (кластер ${PG_CLUSTER}, порт ${PG_PORT}) уже установлен"
  else
    install_postgres
    detect_cluster
    [[ -n "$PG_VER" ]] || die "Кластер PostgreSQL не найден после установки"
  fi

  systemctl enable postgresql >/dev/null 2>&1 || true
  if systemctl is-active --quiet "$SVC"; then
    log "Сервис $SVC запущен"
  else
    warn "Сервис $SVC не запущен — запускаю"
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
    warn "Файрвол ufw не активен."
    if [[ -t 0 && "$ASSUME_YES" != 1 ]]; then
      if confirm "Настроить ufw сейчас?"; then cmd_firewall_init; fi
    fi
  else
    apply_ufw_defaults
  fi

  print_network_summary
  log "Готово. Дальше: $SELF db-create <имя_бд> [владелец] [IP-клиента]"
}

cmd_network() { # смена режима сети (local / private / public) на уже установленном сервере
  ensure_running
  cmd_analyze
  select_network 1
  step_tuning
  apply_ufw_defaults
  print_network_summary
}

# ---------------------------------------------------------- команды БД ----

cmd_db_create() {
  ensure_running
  local db="${1:-}" owner="${2:-}" cidr="${3:-}" enc
  if [[ -z "$db" ]]; then ask db "Имя БД (например calculate_db)"; fi
  validate_db "$db"
  if [[ -z "$owner" ]]; then ask owner "Владелец БД" "${db}_owner"; fi
  validate_user "$owner"
  resolve_cidrs "$cidr"

  create_login_role "$owner"
  if db_exists "$db"; then
    log "БД '$db' уже существует — проверяю права и группы"
  else
    enc="$(psql_val "SELECT pg_encoding_to_char(encoding) FROM pg_database WHERE datname='template1'")"
    if [[ "$enc" == "UTF8" ]]; then
      psql_admin -d postgres -c "CREATE DATABASE \"$db\" OWNER \"$owner\" ENCODING 'UTF8'"
    else
      warn "template1 в кодировке $enc — создаю БД из template0 с C.UTF-8"
      psql_admin -d postgres -c \
        "CREATE DATABASE \"$db\" OWNER \"$owner\" TEMPLATE template0 ENCODING 'UTF8' LC_COLLATE 'C.UTF-8' LC_CTYPE 'C.UTF-8'"
    fi
    log "Создана БД '$db' (владелец '$owner')"
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
  if [[ -z "$db" ]]; then ask db "Имя БД для УДАЛЕНИЯ"; fi
  validate_db "$db"
  db_exists "$db" || die "БД '$db' не существует"
  owner="$(db_owner "$db")"
  warn "БД '$db' (владелец '$owner') будет удалена безвозвратно. Перед этим сохраню финальный дамп."
  confirm_typed "$db" || { log "Отменено"; return 0; }

  install -d -o postgres -g postgres -m 700 "$BACKUP_DIR"
  f="${BACKUP_DIR}/${db}_final_$(date +%F_%H%M).dump"
  runuser -u postgres -- pg_dump -Fc -f "$f" "$db"
  log "Финальный дамп: $f"

  terminate_db_sessions "$db"
  psql_admin -d postgres -c "DROP DATABASE \"$db\""
  psql_admin -d postgres -c "DROP ROLE IF EXISTS \"${db}_rw\""
  psql_admin -d postgres -c "DROP ROLE IF EXISTS \"${db}_ro\""
  hba_del "$db" '*'
  log "БД '$db' удалена (группы ${db}_rw/${db}_ro и правила pg_hba тоже)"

  if [[ "$owner" != "postgres" ]] \
     && [[ "$(psql_val "SELECT count(*) FROM pg_database WHERE datdba=(SELECT oid FROM pg_roles WHERE rolname='$owner')")" == 0 ]]; then
    if confirm "Пользователь '$owner' больше не владеет БД. Удалить и его?"; then
      cmd_user_drop "$owner"
    fi
  fi
}

cmd_db_rename() {
  ensure_running
  local old="${1:-}" new="${2:-}" suf f
  if [[ -z "$old" ]]; then ask old "Текущее имя БД"; fi
  if [[ -z "$new" ]]; then ask new "Новое имя БД"; fi
  validate_db "$old"; validate_db "$new"
  db_exists "$old" || die "БД '$old' не существует"
  ! db_exists "$new" || die "БД '$new' уже существует"
  warn "Активные подключения к '$old' будут разорваны; строки подключения приложений придётся обновить."
  confirm "Переименовать '$old' -> '$new'?" || { log "Отменено"; return 0; }
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
  log "БД переименована: '$old' -> '$new'"
}

cmd_db_chown() {
  ensure_running
  local db="${1:-}" u="${2:-}"
  if [[ -z "$db" ]]; then ask db "Имя БД"; fi
  if [[ -z "$u" ]]; then ask u "Новый владелец"; fi
  validate_db "$db"; validate_user "$u"
  db_exists "$db" || die "БД '$db' не существует"
  if ! role_exists "$u"; then
    confirm "Пользователя '$u' нет. Создать?" || { log "Отменено"; return 0; }
    create_login_role "$u"
    show_credentials "$u" "$db"
  fi
  set_membership "$db" "$u" none
  set_db_owner "$db" "$u"
}

# ---------------------------------------------------- команды пользователей ----

cmd_user_create() {
  ensure_running
  local u="${1:-}" db="${2:-}" profile="${3:-}" cidr="${4:-}"
  if [[ -z "$u" ]]; then ask u "Имя пользователя"; fi
  validate_user "$u"
  if [[ -z "$db" && -t 0 ]]; then ask db "БД для доступа (Enter — без доступа)" ""; fi
  if [[ -n "$db" ]]; then
    validate_db "$db"
    db_exists "$db" || die "БД '$db' не существует (создайте: $SELF db-create $db)"
    if [[ -z "$profile" ]]; then ask profile "Профиль на '$db' (owner / readwrite / readonly)" "readwrite"; fi
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
  if [[ -z "$u" ]]; then ask u "Пользователь"; fi
  if [[ -z "$db" ]]; then ask db "БД"; fi
  if [[ -z "$profile" ]]; then ask profile "Новый профиль (owner / readwrite / readonly / none)" "readwrite"; fi
  validate_user "$u"; validate_db "$db"
  profile="$(normalize_profile "$profile")"
  role_exists "$u" || die "Пользователь '$u' не существует"
  db_exists "$db" || die "БД '$db' не существует"
  apply_profile "$db" "$u" "$profile"
}

cmd_user_passwd() {
  ensure_running
  local u="${1:-}" esc
  if [[ -z "$u" ]]; then ask u "Пользователь"; fi
  validate_user "$u"
  role_exists "$u" || die "Пользователь '$u' не существует"
  choose_password "$u"
  esc="$(sql_lit "$PASSWORD_INPUT")"
  psql_admin -d postgres <<SQL
ALTER ROLE "$u" PASSWORD '$esc';
SQL
  CREATED_PASSWORD="$PASSWORD_INPUT"
  log "Пароль '$u' изменён"
  show_credentials "$u" ""
}

cmd_user_limit() {
  ensure_running
  local u="${1:-}" n="${2:-}"
  if [[ -z "$u" ]]; then ask u "Пользователь"; fi
  if [[ -z "$n" ]]; then ask n "Лимит одновременных подключений (-1 — без лимита)" "-1"; fi
  validate_user "$u"
  [[ "$n" =~ ^-?[0-9]+$ ]] || die "Лимит должен быть целым числом"
  role_exists "$u" || die "Пользователь '$u' не существует"
  psql_admin -d postgres -c "ALTER ROLE \"$u\" CONNECTION LIMIT $n"
  log "Лимит подключений '$u' = $n"
}

cmd_user_rename() {
  ensure_running
  local old="${1:-}" new="${2:-}" f
  if [[ -z "$old" ]]; then ask old "Текущее имя пользователя"; fi
  if [[ -z "$new" ]]; then ask new "Новое имя"; fi
  validate_user "$old"; validate_user "$new"
  role_exists "$old" || die "Пользователь '$old' не существует"
  ! role_exists "$new" || die "Роль '$new' уже существует"
  confirm "Переименовать '$old' -> '$new'?" || { log "Отменено"; return 0; }
  psql_admin -d postgres -c "ALTER ROLE \"$old\" RENAME TO \"$new\""
  f="$(hba_file)"
  sed -i "/# ${TAG}:[a-z0-9_]*:${old}\$/{s/^\(hostssl [a-z0-9_]* \)${old} /\1${new} /;s/:${old}\$/:${new}/}" "$f"
  reload_pg
  log "Пользователь переименован: '$old' -> '$new' (строки подключения обновите)"
}

cmd_user_drop() {
  ensure_running
  local u="${1:-}" d owner owned
  if [[ -z "$u" ]]; then ask u "Пользователь для УДАЛЕНИЯ"; fi
  validate_user "$u"
  role_exists "$u" || die "Пользователь '$u' не существует"
  owned="$(psql_val "SELECT string_agg(datname, ', ') FROM pg_database WHERE datdba=(SELECT oid FROM pg_roles WHERE rolname='$u')")"
  if [[ -n "$owned" ]]; then
    die "'$u' владеет БД: $owned. Передайте владение (db-chown) или удалите БД (db-drop)."
  fi
  warn "Пользователь '$u' будет удалён."
  confirm_typed "$u" || { log "Отменено"; return 0; }
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
  log "Пользователь '$u' удалён"
}

# ------------------------------------------------------------- доступ ----

cmd_access_add() {
  ensure_running
  local db="${1:-}" u="${2:-}" cidr="${3:-}" list
  if [[ -z "$db" ]]; then ask db "БД"; fi
  if [[ -z "$u" ]]; then ask u "Пользователь"; fi
  if [[ -z "$cidr" ]]; then ask cidr "IP/CIDR клиентов через запятую (например 203.0.113.10, 198.51.100.0/24)"; fi
  validate_db "$db"; validate_user "$u"
  db_exists "$db" || die "БД '$db' не существует"
  role_exists "$u" || die "Пользователь '$u' не существует"
  list="$(normalize_cidr_list "$cidr")" || exit 1
  if [[ ",$list," == *,0.0.0.0/0,* ]]; then
    warn "0.0.0.0/0 открывает доступ '$u' к '$db' из всего интернета."
    confirm_typed "ВСЕМ" || { log "Отменено"; return 0; }
  fi
  apply_access "$db" "$u" "$list"
}

cmd_access_del() {
  ensure_running
  local db="${1:-}" u="${2:-}"
  if [[ -z "$db" ]]; then ask db "БД (или *)"; fi
  if [[ -z "$u" ]]; then ask u "Пользователь (или *)"; fi
  if [[ "$db" != "*" ]]; then validate_db "$db"; fi
  if [[ "$u" != "*" ]]; then validate_user "$u"; fi
  hba_del "$db" "$u"
  log "Правила pg_hba для $db / $u удалены. Правила ufw (если были) проверьте: ufw status numbered"
}

# ------------------------------------------------------ информация ----

cmd_list() {
  ensure_running
  echo "--- Базы данных ---"
  psql_admin -d postgres -c "SELECT d.datname AS db, pg_get_userbyid(d.datdba) AS owner, pg_size_pretty(pg_database_size(d.datname)) AS size FROM pg_database d WHERE NOT d.datistemplate ORDER BY 1"
  echo "--- Пользователи ---"
  psql_admin -d postgres -c "SELECT rolname AS \"user\", rolcanlogin AS login, rolconnlimit AS conn_limit, rolsuper AS super FROM pg_roles WHERE rolname !~ '^pg_' AND rolname !~ '_(rw|ro)\$' ORDER BY 1"
  echo "--- Профили (пользователь -> БД) ---"
  psql_admin -d postgres -c "SELECT m.rolname AS \"user\", regexp_replace(g.rolname, '_(rw|ro)\$', '') AS db, CASE WHEN g.rolname ~ '_rw\$' THEN 'readwrite' ELSE 'readonly' END AS profile FROM pg_auth_members am JOIN pg_roles g ON g.oid = am.roleid JOIN pg_roles m ON m.oid = am.member WHERE g.rolname ~ '_(rw|ro)\$' AND EXISTS (SELECT 1 FROM pg_database d WHERE d.datname = regexp_replace(g.rolname, '_(rw|ro)\$', '')) UNION ALL SELECT pg_get_userbyid(datdba), datname, 'owner' FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres' ORDER BY 2, 1"
  echo "--- Правила удалённого доступа (pg_hba, управляются скриптом) ---"
  grep "# ${TAG}:" "$(hba_file)" || echo "(нет)"
  print_network_summary
}

cmd_status() {
  detect_cluster
  if [[ -z "$PG_VER" ]]; then
    warn "PostgreSQL не установлен. Выполните: $SELF setup"
    return 0
  fi
  echo "--- Сервис ---"
  pg_lsclusters
  if systemctl is-active --quiet "$SVC"; then
    log "$SVC: active"
    psql_admin -d postgres -c "SELECT version()"
    psql_admin -d postgres -c "SELECT current_setting('listen_addresses') AS listen, current_setting('max_connections') AS max_conn, (SELECT count(*) FROM pg_stat_activity) AS connections, current_setting('shared_buffers') AS shared_buffers, current_setting('ssl') AS ssl"
  else
    warn "$SVC: НЕ запущен"
  fi
  analyze_hardware
  print_hw_report
  print_network_summary
  echo "--- Последний бэкап ---"
  find "$BACKUP_DIR" -name '*.dump' -printf '%TY-%Tm-%Td %TH:%TM  %p\n' 2>/dev/null | sort | tail -n1 || true
  if ufw_active; then echo "--- ufw: активен ---"; else echo "--- ufw: не активен ---"; fi
}

cmd_backup_now() {
  ensure_running
  [[ -x "$BACKUP_BIN" ]] || step_backup
  runuser -u postgres -- "$BACKUP_BIN"
  log "Бэкап выполнен -> $BACKUP_DIR"
}

# ------------------------------------------------------------- меню ----

usage() {
  cat <<EOF
Использование: $(basename "$SELF") [-y] <команда> [аргументы]

  setup                                  анализ сервера, установка, режим сети, тюнинг (идемпотентно)
  analyze                                анализ ядер / RAM / диска
  network                                сменить режим сети: local | private | public (list/all)
  port        [N|default|random]         сменить порт: 5432, свой или случайный свободный
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
}

menu() {
  local choice
  while true; do
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
  0) Выход
EOF
    read -r -p "Выбор: " choice || return 0
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
      0|q|Q) return 0 ;;
      *) warn "Неизвестный пункт" ;;
    esac
  done
}

main() {
  cd /
  while [[ "${1:-}" == -* ]]; do
    case "$1" in
      -y|--yes)  ASSUME_YES=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Неизвестный флаг: $1" ;;
    esac
    shift
  done
  local cmd="${1:-menu}"
  if [[ $# -gt 0 ]]; then shift; fi
  require_root
  case "$cmd" in
    menu)          menu ;;
    setup)         cmd_setup "$@" ;;
    analyze)       cmd_analyze "$@" ;;
    network)       cmd_network "$@" ;;
    port)          cmd_port "$@" ;;
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
    *) usage; die "Неизвестная команда: $cmd" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
