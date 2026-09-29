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
#   EXTERNAL_PORT=<number>|none         (server behind NAT: external port for clients)
#   PG_VERSION=17  MAX_CONNECTIONS=<N>  STORAGE=ssd|hdd  SWAP_GB=2
#   BACKUP_DIR=/var/backups/postgresql  BACKUP_RETENTION_DAYS=14
#   PGMGR_PASSWORD=...  (ready-made password for the created/changed user)

set -Eeuo pipefail
shopt -s extglob

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
readonly SELF
readonly TAG="pgmgr"
readonly CONF_NAME="99-pgmgr.conf"
readonly BACKUP_BIN="/usr/local/sbin/pgmgr-backup"
readonly BACKUP_CRON="/etc/cron.d/pgmgr-backup"
readonly STATE_DIR="/etc/pgmgr"
readonly STATE_FILE="${STATE_DIR}/pgmgr.conf"
readonly MIN_PASSWORD_LEN=6

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
EXTERNAL_PORT="${EXTERNAL_PORT:-}"   # external (NAT) port shown to clients
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

# ------------------------------------------------------------------ UI ----
# Colours, icons and boxes are enabled only when stdout is a terminal
# (and NO_COLOR is unset); pipes and logs stay plain text.

readonly SCRIPT_VERSION="2.0.0"
UI_ON=0          # stdout is a terminal: colours, icons, spinner
INTERACTIVE=0    # stdin and stdout are terminals: clear screen, pauses
UTF=0
BOX_W=70
C_RESET=""; C_BOLD=""; C_DIM=""; C_INV=""
C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_MAGENTA=""; C_CYAN=""
G1=""; G2=""; G3=""
I_OK="[+]"; I_WARN="[!]"; I_ERR="[x]"; I_INFO="[i]"; I_SKIP="[-]"; I_Q="?"; I_ARROW=">"; I_DOT="*"
B_TL="+"; B_TR="+"; B_BL="+"; B_BR="+"; B_H="-"; B_V="|"; B_HH="="
SPIN=('|' '/' '-' '\')
BC=""            # colour of the box currently being drawn

ui_init() {
  local cols ncolors=8
  if [[ ( -t 1 || "${PGMGR_FORCE_UI:-}" == 1 ) && "${TERM:-dumb}" != dumb ]]; then UI_ON=1; fi
  if [[ "$UI_ON" == 1 && -t 0 ]]; then INTERACTIVE=1; fi
  if [[ "$UI_ON" != 1 ]]; then return 0; fi

  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8*|*utf-8*|*UTF8*|*utf8*) UTF=1 ;;
  esac
  if [[ "${PGMGR_ASCII:-}" == 1 ]]; then UTF=0; fi

  if [[ -z "${NO_COLOR:-}" ]]; then
    ncolors="$(tput colors 2>/dev/null || echo 8)"
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_INV=$'\033[7m'
    C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'
    C_BLUE=$'\033[1;34m'; C_MAGENTA=$'\033[1;35m'; C_CYAN=$'\033[1;36m'
    if (( ncolors >= 256 )); then
      G1=$'\033[1;38;5;27m'; G2=$'\033[1;38;5;33m'; G3=$'\033[1;38;5;39m'
    else
      G1="$C_BLUE"; G2="$C_CYAN"; G3="$C_CYAN"
    fi
  fi

  if [[ "$UTF" == 1 ]]; then
    I_OK="✔"; I_WARN="⚠"; I_ERR="✖"; I_INFO="●"; I_SKIP="↷"; I_Q="›"; I_ARROW="▶"; I_DOT="●"
    B_TL="╭"; B_TR="╮"; B_BL="╰"; B_BR="╯"; B_H="─"; B_V="│"; B_HH="━"
    SPIN=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  fi

  cols="$(tput cols 2>/dev/null || echo 80)"
  BOX_W=$(( cols - 4 ))
  if (( BOX_W > 84 )); then BOX_W=84; fi
  if (( BOX_W < 64 )); then BOX_W=64; fi
}

rep() { # rep CHAR COUNT
  local s
  if (( $2 <= 0 )); then return 0; fi
  printf -v s '%*s' "$2" ''
  printf '%s' "${s// /$1}"
}

log()  { printf '  %s%s%s %s\n' "$C_GREEN" "$I_OK" "$C_RESET" "$*"; }
info() { printf '  %s%s%s %s\n' "$C_CYAN" "$I_INFO" "$C_RESET" "$*"; }
skip() { printf '  %s%s %s%s\n' "$C_DIM" "$I_SKIP" "$*" "$C_RESET"; }
warn() { printf '  %s%s%s %s\n' "$C_YELLOW" "$I_WARN" "$C_RESET" "$*" >&2; }
die()  { printf '  %s%s %s%s\n' "$C_RED" "$I_ERR" "$*" "$C_RESET" >&2; exit 1; }

ui_cleanup() { if [[ "$UI_ON" == 1 ]]; then printf '\033[?25h'; fi; }
SETUP_ACTIVE=0   # 1 while `setup` is running (used to report an interrupted run)
SETUP_STEP=0
SETUP_TOTAL=8

# On any non-zero exit during `setup`, remember that it was interrupted: the next
# run verifies every step against the real system state and continues.
on_exit() {
  local rc=$?
  ui_cleanup
  if [[ "$SETUP_ACTIVE" == 1 && $rc -ne 0 ]]; then
    state_set SETUP_STATUS interrupted 2>/dev/null || true
    printf '\n  %s%s %s%s\n' "$C_YELLOW" "$I_WARN" \
      "$(L "Настройка прервана на шаге ${SETUP_STEP}/${SETUP_TOTAL}. Запустите 'sudo $SELF setup' ещё раз: уже выполненное будет проверено и пропущено, работа продолжится с места остановки." \
           "Setup was interrupted at step ${SETUP_STEP}/${SETUP_TOTAL}. Run 'sudo $SELF setup' again: completed work is verified and skipped, and it continues where it stopped.")" \
      "$C_RESET" >&2
  fi
}
trap on_exit EXIT
trap 'ui_cleanup; printf "\n"; exit 130' INT
trap 'warn "$(L "Сбой на строке ${LINENO} (команда: ${BASH_COMMAND})" "Failure at line ${LINENO} (command: ${BASH_COMMAND})")"' ERR

clear_screen() {
  if [[ "$INTERACTIVE" == 1 && "$ASSUME_YES" != 1 ]]; then printf '\033[H\033[2J\033[3J'; fi
}

section() { # section "Title"
  local t="$1"
  printf '\n  %s%s%s %s%s%s %s%s%s\n' "$C_BLUE" "$(rep "$B_HH" 2)" "$C_RESET" "$C_BOLD" "$t" "$C_RESET" \
    "$C_BLUE" "$(rep "$B_HH" $(( BOX_W - ${#t} - 4 )))" "$C_RESET"
}

box_top() { # box_top "Title" [colour]
  local t="$1"
  BC="${2:-$C_CYAN}"
  printf '  %s%s%s %s%s%s %s%s%s\n' "$BC" "$B_TL$B_H" "$C_RESET" "$C_BOLD$BC" "$t" "$C_RESET" \
    "$BC" "$(rep "$B_H" $(( BOX_W - ${#t} - 5 )))$B_TR" "$C_RESET"
}

box_row() { # box_row "plain text" [colour]
  local t="$1" c="${2:-}" pad max=$(( BOX_W - 4 ))
  if (( ${#t} > max )); then t="${t:0:max-1}…"; fi
  pad=$(( BOX_W - 4 - ${#t} ))
  if (( pad < 0 )); then pad=0; fi
  printf '  %s%s%s %s%s%s%*s %s%s%s\n' "$BC" "$B_V" "$C_RESET" "$c" "$t" "$C_RESET" "$pad" "" "$BC" "$B_V" "$C_RESET"
}

box_raw() { # box_raw "text that already contains colour codes"
  local t="$1" plain pad
  plain="${t//$'\033'\[+([0-9;])m/}"
  pad=$(( BOX_W - 4 - ${#plain} ))
  if (( pad < 0 )); then pad=0; fi
  printf '  %s%s%s %s%*s %s%s%s\n' "$BC" "$B_V" "$C_RESET" "$t" "$pad" "" "$BC" "$B_V" "$C_RESET"
}

box_kv() { # box_kv "Label" "Value" [value colour]
  local lab="$1" val="$2" c="${3:-$C_BOLD}" lpad pad max
  lpad=$(( 16 - ${#lab} ))
  if (( lpad < 1 )); then lpad=1; fi
  max=$(( BOX_W - 4 - ${#lab} - lpad ))
  if (( ${#val} > max )); then val="${val:0:max-1}…"; fi
  pad=$(( BOX_W - 4 - ${#lab} - lpad - ${#val} ))
  if (( pad < 0 )); then pad=0; fi
  printf '  %s%s%s %s%s%s%*s%s%s%s%*s %s%s%s\n' "$BC" "$B_V" "$C_RESET" "$C_DIM" "$lab" "$C_RESET" "$lpad" "" \
    "$c" "$val" "$C_RESET" "$pad" "" "$BC" "$B_V" "$C_RESET"
}

box_bottom() {
  printf '  %s%s%s\n' "$BC" "$B_BL$(rep "$B_H" $(( BOX_W - 2 )))$B_BR" "$C_RESET"
}

progress_bar() { # progress_bar current total
  local cur="$1" tot="$2" w=28 filled full empty
  filled=$(( cur * w / tot ))
  if [[ "$UTF" == 1 ]]; then full="█"; empty="░"; else full="#"; empty="."; fi
  printf '%s%s%s%s%s%s %s%d%%%s' "$C_GREEN" "$(rep "$full" "$filled")" "$C_RESET" "$C_DIM" "$(rep "$empty" $(( w - filled )))" \
    "$C_RESET" "$C_BOLD" $(( cur * 100 / tot )) "$C_RESET"
}

step_header() { # step_header n total "title"
  SETUP_STEP="$1"
  if [[ "$SETUP_ACTIVE" == 1 ]]; then state_set SETUP_LAST_STEP "$1"; fi
  printf '\n  %s%s [%d/%d] %s%s\n  %s\n' "$C_MAGENTA" "$I_ARROW" "$1" "$2" "$3" "$C_RESET" "$(progress_bar "$1" "$2")"
}

# run_step "message" command args... — command runs in the background with a spinner.
# Output is kept in a temp file and shown only on failure.
run_step() {
  local msg="$1" logf pid rc=0 i=0
  shift
  if [[ "$UI_ON" != 1 ]]; then
    info "$msg"
    "$@"
    return $?
  fi
  logf="$(mktemp)"
  "$@" >"$logf" 2>&1 &
  pid=$!
  printf '\033[?25l'
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s%s%s %s' "$C_CYAN" "${SPIN[i % ${#SPIN[@]}]}" "$C_RESET" "$msg"
    i=$(( i + 1 ))
    sleep 0.1
  done
  wait "$pid" || rc=$?
  printf '\r\033[K\033[?25h'
  if (( rc == 0 )); then
    log "$msg"
  else
    printf '  %s%s %s%s\n' "$C_RED" "$I_ERR" "$msg" "$C_RESET" >&2
    tail -n 15 "$logf" | sed 's/^/      /' >&2
    rm -f "$logf"
    return "$rc"
  fi
  rm -f "$logf"
}

banner() {
  local host
  host="$(hostname 2>/dev/null || echo server)"
  echo
  if [[ "$UTF" == 1 ]]; then
    printf '  %s┏━┓┏━╸  ┏━┓┏━╸╺┳╸╻ ╻┏━┓%s\n' "$G1" "$C_RESET"
    printf '  %s┣━┛┃╺┓  ┗━┓┣╸  ┃ ┃ ┃┣━┛%s   %sPostgreSQL VPS manager%s\n' "$G2" "$C_RESET" "$C_BOLD" "$C_RESET"
    printf '  %s╹  ┗━┛  ┗━┛┗━╸ ╹ ┗━┛╹  %s   %sv%s · %s%s\n' "$G3" "$C_RESET" "$C_DIM" "$SCRIPT_VERSION" "$host" "$C_RESET"
  else
    printf '  %s== PG SETUP ==%s  PostgreSQL VPS manager\n' "$C_CYAN" "$C_RESET"
    printf '  %sv%s - %s%s\n' "$C_DIM" "$SCRIPT_VERSION" "$host" "$C_RESET"
  fi
  printf '  %s%s%s\n' "$C_DIM" "$(rep "$B_H" "$BOX_W")" "$C_RESET"
}

screen_begin() { # screen_begin "Title" — clean screen + banner + title bar
  clear_screen
  if [[ "$UI_ON" == 1 ]]; then
    banner
    printf '\n  %s %s %s\n' "$C_INV$C_CYAN" "$1" "$C_RESET"
  fi
}

pause_return() {
  if [[ "$INTERACTIVE" != 1 ]]; then return 0; fi
  printf '\n  %s%s%s\n' "$C_DIM" "$(rep "$B_H" "$BOX_W")" "$C_RESET"
  read -r -p "  $(L "Нажмите Enter, чтобы вернуться в меню…" "Press Enter to return to the menu…")" _ || true
}

# Boxes and Russian text need character-based string lengths: on servers with a
# POSIX/unset locale switch to C.UTF-8 (present on Debian/Ubuntu) when available.
fix_locale() {
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8*|*utf-8*|*UTF8*|*utf8*) return 0 ;;
  esac
  if locale -a 2>/dev/null | grep -qix 'c\.utf-\?8'; then export LC_ALL=C.UTF-8; fi
}

fix_locale
ui_init

require_root() {
  [[ $EUID -eq 0 ]] || die "$(L "Запустите от root: sudo $SELF" "Run as root: sudo $SELF")"
}

ask() { # ask VAR "question" [default]
  local __var="$1" __prompt="$2" __def="${3:-}" __ans=""
  [[ -t 0 ]] || die "$(L "Не хватает аргумента: $__prompt (нет интерактивного ввода)" "Missing argument: $__prompt (no interactive input)")"
  read -r -p "  ${C_CYAN}${I_Q}${C_RESET} ${__prompt}${__def:+ ${C_DIM}[$__def]${C_RESET}}: " __ans || die "$(L "Ввод прерван" "Input interrupted")"
  printf -v "$__var" '%s' "${__ans:-$__def}"
}

pick() { # pick VAR "title" default_number option1 option2 ... -> VAR = number
  local __var="$1" __title="$2" __def="$3" __i=1 __o __pa=""
  shift 3
  printf '\n  %s%s%s\n' "$C_BOLD" "$__title" "$C_RESET"
  for __o in "$@"; do
    printf '    %s%2d%s  %s\n' "$C_CYAN" "$__i" "$C_RESET" "$__o"
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
  read -r -p "  ${C_YELLOW}?${C_RESET} $1 ${C_DIM}[y/N]${C_RESET} " a || return 1
  [[ "$a" =~ ^[YyДд] ]]
}

confirm_typed() { # requires typing the word/name in full
  if [[ "$ASSUME_YES" == 1 ]]; then return 0; fi
  local a=""
  [[ -t 0 ]] || die "$(L "Нужно подтверждение, но нет интерактивного ввода (используйте -y)" "Confirmation required but no interactive input (use -y)")"
  read -r -p "  ${C_YELLOW}?${C_RESET} $(L "Для подтверждения введите '${C_BOLD}$1${C_RESET}': " "Type '${C_BOLD}$1${C_RESET}' to confirm: ")" a || return 1
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
      clear_screen
      if [[ "$UI_ON" == 1 ]]; then banner; fi
      printf '\n  %sLanguage / Язык%s\n    %s1%s  English\n    %s2%s  Русский\n\n' "$C_BOLD" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
      read -r -p "  ${C_CYAN}${I_Q}${C_RESET} [1/2] ($def): " a || a=""
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
    psql -X -q -P pager=off -v ON_ERROR_STOP=1 "$@"
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
  HW_AVAIL_MB=$(( $(awk '/^MemAvailable:/{a=$2} /^MemFree:/{f=$2} /^Buffers:/{b=$2} /^Cached:/{c=$2} END{print (a != "") ? a : f + b + c}' /proc/meminfo) / 1024 ))
  HW_SWAP_MB=$(( $(awk '/^SwapTotal:/{t=$2} END{print t + 0}' /proc/meminfo) / 1024 ))
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
  echo
  box_top "$(L "Анализ сервера" "Server analysis")" "$C_CYAN"
  box_kv "CPU" "$(L "$HW_CORES ядер" "$HW_CORES cores")"
  box_kv "RAM" "$(L "$(gb "$HW_MEM_MB") ГБ всего · $(gb "$HW_AVAIL_MB") ГБ свободно · занято $(gb "$used") ГБ" "$(gb "$HW_MEM_MB") GB total · $(gb "$HW_AVAIL_MB") GB free · used $(gb "$used") GB")"
  box_kv "Swap" "$(L "$(gb "$HW_SWAP_MB") ГБ" "$(gb "$HW_SWAP_MB") GB")"
  box_kv "$(L "Диск" "Disk")" "$(L "$HW_DISK_FREE_GB ГБ свободно из $HW_DISK_TOTAL_GB ГБ ($HW_DISK_PATH)" "$HW_DISK_FREE_GB GB free of $HW_DISK_TOTAL_GB GB ($HW_DISK_PATH)")"
  box_kv "$(L "Тип диска" "Disk type")" "$(L "$STORAGE (ядро: $HW_STORAGE_DETECTED; виртуализация: $HW_VIRT)" "$STORAGE (kernel: $HW_STORAGE_DETECTED; virtualization: $HW_VIRT)")"
  box_bottom
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
  state_set PUBLIC_IP ""
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
  if [[ -t 0 && "$ASSUME_YES" != 1 ]]; then select_nat 1; fi
}

# Port that clients must use: the external NAT port when set, otherwise the real one.
client_port() {
  local e
  e="$(state_get EXTERNAL_PORT)"
  echo "${e:-$PG_PORT}"
}

# What PostgreSQL really speaks: TCP only (UDP is not supported by the protocol).
proto_value() {
  if port_in_use "$PG_PORT"; then echo "TCP ($(L "слушает" "listening"))"; else echo "TCP"; fi
}

# NAT / port forwarding: the external port assigned by the provider (read-only for
# you, but visible in its panel). Only affects what is shown in the connection
# details — the firewall and pg_hba use the real port.
select_nat() { # select_nat [force=0]
  local force="${1:-0}" ext="${EXTERNAL_PORT:-}" asked cur idx=1 def=1
  asked="$(state_get NAT_ASKED)"
  cur="$(state_get EXTERNAL_PORT)"

  if [[ -z "$ext" && -n "$asked" && "$force" != 1 ]]; then
    EXTERNAL_PORT="$cur"
    if [[ -n "$cur" ]]; then
      skip "$(L "NAT (из сохранённых настроек): внешний порт $cur -> $PG_PORT" "NAT (from saved settings): external port $cur -> $PG_PORT")"
    else
      skip "$(L "NAT: сервер доступен напрямую (внешний порт = внутренний)" "NAT: the server is reachable directly (external port = internal port)")"
    fi
    return 0
  fi

  if [[ -z "$ext" ]]; then
    if [[ -t 0 ]]; then
      if [[ -n "$cur" ]]; then def=2; fi
      pick idx "$(L "Сервер за NAT с пробросом порта?" "Is the server behind NAT with port forwarding?")" "$def" \
        "$(L "Нет — внешний порт совпадает с внутренним" "No — the external port equals the internal port")" \
        "$(L "Да — внешний порт назначен провайдером" "Yes — the provider assigned an external port")"
      if (( idx == 2 )); then
        info "$(L "Примечание: PostgreSQL использует соединение TCP (UDP не поддерживает) — в панели провайдера нужен проброс типа TCP." "Note: PostgreSQL uses a TCP connection (UDP is not supported) — the provider's port forward must be of type TCP.")"
        ask ext "$(L "Внешний порт (посмотрите в панели провайдера)" "External port (see your provider's panel)")" "$cur"
      else
        ext=none
      fi
    else
      ext="${cur:-none}"
    fi
  fi
  case "$ext" in
    none|"") ext="" ;;
  esac

  if [[ -n "$ext" ]]; then
    if ! [[ "$ext" =~ ^[0-9]+$ ]] || (( ext < 1 || ext > 65535 )); then
      die "$(L "Внешний порт должен быть числом 1-65535: '$ext'" "The external port must be a number 1-65535: '$ext'")"
    fi
  fi

  EXTERNAL_PORT="$ext"
  state_set EXTERNAL_PORT "$ext"
  state_set NAT_ASKED yes
  if [[ -n "$ext" ]]; then
    log "$(L "NAT: внешний порт $ext -> внутренний $PG_PORT" "NAT: external port $ext -> internal $PG_PORT")"
  else
    log "$(L "NAT: сервер доступен напрямую (внешний порт = внутренний)" "NAT: the server is reachable directly (external port = internal port)")"
  fi
}

cmd_nat() { # cmd_nat [external_port|none]
  ensure_running
  local arg="${1:-}"
  if [[ -n "$arg" ]]; then EXTERNAL_PORT="$arg"; fi
  select_nat 1
  print_network_summary
}

# IP clients use to connect to this server (by network mode).
route_src_ip() { # source IP of the default route
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}'
}

# Public address as seen from the internet (for servers behind NAT, where the
# public IP is not configured on any interface). Asks a public IP-echo service.
external_ip() {
  local ip="" url
  for url in https://api.ipify.org https://ifconfig.me/ip; do
    ip="$(curl -4fsS --max-time 4 "$url" 2>/dev/null || true)"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then printf '%s' "$ip"; return 0; fi
  done
  return 1
}

# IP or host clients use to connect to this server. Order: PGMGR_HOST env, saved
# CONNECT_HOST, listen address, interface addresses, default-route source, public
# IP-echo lookup (public mode only, result cached in the state file).
connect_host() {
  local mode listen it ip
  local -a items
  if [[ -n "${PGMGR_HOST:-}" ]]; then printf '%s\n' "$PGMGR_HOST"; return 0; fi
  ip="$(state_get CONNECT_HOST)"
  if [[ -n "$ip" ]]; then printf '%s\n' "$ip"; return 0; fi
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

  # listen = '*': work out which address clients should use
  collect_ips "$mode"
  if (( ${#IP_CANDS[@]} > 0 )); then ip_of "${IP_CANDS[0]}"; return 0; fi
  ip="$(route_src_ip)"
  if [[ "$mode" == private ]]; then
    if [[ -n "$ip" ]] && is_private_ip "$ip"; then echo "$ip"; return 0; fi
  else
    if [[ -n "$ip" ]] && ! is_private_ip "$ip"; then echo "$ip"; return 0; fi
    ip="$(state_get PUBLIC_IP)"
    if [[ -n "$ip" ]]; then echo "$ip"; return 0; fi
    if ip="$(external_ip)"; then
      state_set PUBLIC_IP "$ip"
      echo "$ip"; return 0
    fi
  fi
  echo "<SERVER_IP>"
}

# If the address could not be detected, ask for it once (interactive runs).
ensure_connect_host() {
  local h
  h="$(connect_host)"
  if [[ "$h" == "<SERVER_IP>" && -t 0 && "$ASSUME_YES" != 1 ]]; then
    warn "$(L "Не удалось определить IP сервера автоматически." "Could not detect the server IP automatically.")"
    ask h "$(L "Введите IP или домен для подключения (Enter — пропустить)" "Enter the IP or domain clients connect to (Enter to skip)")" ""
    if [[ -n "$h" ]]; then
      state_set CONNECT_HOST "$h"
      log "$(L "Адрес подключения сохранён: $h" "Connection address saved: $h")"
    fi
  fi
}

print_network_summary() {
  local mode pcolor="$C_GREEN" cport ext
  mode="$(state_get NETWORK_MODE)"
  ext="$(state_get EXTERNAL_PORT)"
  cport="$(client_port)"
  if [[ "$mode" == public ]]; then pcolor="$C_YELLOW"; fi
  echo
  box_top "$(L "Сеть" "Network")" "$C_MAGENTA"
  box_kv "$(L "IP подключения" "Connect IP")" "$(connect_host)" "$C_GREEN$C_BOLD"
  box_kv "$(L "Порт клиента" "Client port")" "$cport" "$C_GREEN$C_BOLD"
  if [[ -n "$ext" ]]; then
    box_kv "$(L "Внутренний порт" "Internal port")" "$PG_PORT"
    box_kv "NAT" "$(L "внешний $ext -> внутренний $PG_PORT" "external $ext -> internal $PG_PORT")"
  fi
  box_kv "$(L "Протокол" "Protocol")" "$(proto_value)" "$C_GREEN$C_BOLD"
  box_kv "$(L "Режим" "Mode")" "${mode:-—}" "$pcolor$C_BOLD"
  box_kv "listen" "$(state_get LISTEN_ADDR)"
  box_kv "$(L "Политика" "Policy")" "$(state_get ACCESS_POLICY)"
  box_kv "$(L "Клиенты" "Clients")" "$(state_get DEFAULT_CIDRS)"
  if [[ "$mode" == public ]]; then
    box_row "" ""
    box_row "$(L "SSL: сертификат самоподписанный — шифрует, но не подтверждает сервер." "SSL: self-signed certificate — encrypts, but does not verify the server.")" "$C_DIM"
    box_row "$(L "Для sslmode=verify-full установите свой (например Let's Encrypt)." "For sslmode=verify-full install your own (e.g. Let's Encrypt).")" "$C_DIM"
  fi
  box_bottom
}

# -------------------------------------------- roles, groups, owners ----

# Password choice: enter your own or generate. -> PASSWORD_INPUT, PASSWORD_GENERATED
# Prints why a custom password is not acceptable (nothing if it is fine):
# only Latin letters (upper/lower case) and digits, at least MIN_PASSWORD_LEN characters.
password_problem() {
  local LC_ALL=C p="$1"
  if ! [[ "$p" =~ ^[A-Za-z0-9]*$ ]]; then
    L "Допустимы только латинские буквы (большие и маленькие) и цифры — без спецсимволов, пробелов и кириллицы"       "Only Latin letters (upper and lower case) and digits are allowed — no special characters, spaces or non-Latin letters"
    return 0
  fi
  if (( ${#p} < MIN_PASSWORD_LEN )); then
    L "Пароль должен содержать не менее ${MIN_PASSWORD_LEN} символов"       "The password must be at least ${MIN_PASSWORD_LEN} characters long"
  fi
}

# Password choice: enter your own or generate. -> PASSWORD_INPUT, PASSWORD_GENERATED
choose_password() { # choose_password "for whom"
  local who="$1" mode=1 p1 p2 problem
  PASSWORD_GENERATED=0
  if [[ -n "${PGMGR_PASSWORD:-}" ]]; then
    PASSWORD_INPUT="$PGMGR_PASSWORD"
    problem="$(password_problem "$PASSWORD_INPUT")"
    [[ -z "$problem" ]] || die "PGMGR_PASSWORD: $problem"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    PASSWORD_INPUT="$(gen_password)"; PASSWORD_GENERATED=1
    return 0
  fi
  pick mode "$(L "Пароль для '$who':" "Password for '$who':")" 1     "$(L "Сгенерировать надёжный случайный (рекомендуется)" "Generate a strong random one (recommended)")"     "$(L "Ввести свой (латинские буквы и цифры, не менее ${MIN_PASSWORD_LEN} символов)" "Enter my own (Latin letters and digits, at least ${MIN_PASSWORD_LEN} characters)")"
  if (( mode == 1 )); then
    PASSWORD_INPUT="$(gen_password)"; PASSWORD_GENERATED=1
    return 0
  fi
  while true; do
    read -rs -p "  ${C_CYAN}${I_Q}${C_RESET} $(L "Введите пароль" "Enter the password"): " p1 || die "$(L "Ввод прерван" "Input interrupted")"; echo
    problem="$(password_problem "$p1")"
    if [[ -n "$problem" ]]; then warn "$problem"; continue; fi
    read -rs -p "  ${C_CYAN}${I_Q}${C_RESET} $(L "Повторите пароль" "Repeat the password"): " p2 || die "$(L "Ввод прерван" "Input interrupted")"; echo
    if [[ "$p1" != "$p2" ]]; then warn "$(L "Пароли не совпадают" "Passwords do not match")"; continue; fi
    PASSWORD_INPUT="$p1"
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

urlencode() { # percent-encode a string for use inside a URL
  local LC_ALL=C s="$1" out="" c i
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) out+="$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "$out"
}

# Databases the user can access (owner or rw/ro profile).
user_databases() {
  psql_val "SELECT COALESCE(string_agg(db, ', ' ORDER BY db), '—') FROM (SELECT datname AS db FROM pg_database WHERE datdba=(SELECT oid FROM pg_roles WHERE rolname='$1') UNION SELECT regexp_replace(g.rolname, '_(rw|ro)\$', '') FROM pg_auth_members am JOIN pg_roles g ON g.oid=am.roleid JOIN pg_roles m ON m.oid=am.member WHERE m.rolname='$1' AND g.rolname ~ '_(rw|ro)\$') t"
}

# Final connection details. The password is shown ONCE: after printing it is
# wiped from the script's memory and never printed again.
show_credentials() { # user [db]
  [[ -n "$CREATED_PASSWORD" ]] || return 0
  local u="$1" db="${2:-}" host db1 url cport port_disp
  if [[ -z "$db" ]]; then db="$(user_databases "$u")"; fi
  host="$(connect_host)"
  cport="$(client_port)"
  port_disp="$cport"
  if [[ "$cport" != "$PG_PORT" ]]; then
    port_disp="$cport ($(L "внутренний" "internal"): $PG_PORT)"
  fi
  echo
  box_top "$(L "Данные для подключения" "Connection details")" "$C_GREEN"
  box_kv "IP" "$host"
  box_kv "$(L "Порт" "Port")" "$port_disp"
  box_kv "$(L "Протокол" "Protocol")" "TCP"
  box_kv "$(L "Название БД" "Database")" "$db"
  box_kv "$(L "Логин" "Login")" "$u"
  box_kv "$(L "Пароль" "Password")" "$CREATED_PASSWORD" "$C_YELLOW$C_BOLD"
  box_kv "SSL" "sslmode=require"
  box_row "" ""
  box_row "$(L "Пароль показан один раз — сохраните его сейчас." "The password is shown only once — save it now.")" "$C_YELLOW"
  box_bottom

  # Plain block for copy & paste (no colours, no decoration) and a ready-to-use URL.
  db1="${db%%,*}"
  url="postgresql://$(urlencode "$u"):$(urlencode "$CREATED_PASSWORD")@${host}:${cport}"
  if [[ -n "$db1" && "$db1" != "—" ]]; then url="${url}/${db1}"; fi
  url="${url}?sslmode=require"
  echo
  printf '%s\n' "$(L "Данные для копирования:" "Copy-paste details:")"
  printf 'IP: %s\n' "$host"
  printf '%s %s\n' "$(L "Порт:" "Port:")" "$cport"
  printf '%s %s\n' "$(L "Протокол:" "Protocol:")" "TCP"
  printf '%s %s\n' "$(L "Название БД:" "Database:")" "$db"
  printf '%s %s\n' "$(L "Логин:" "Login:")" "$u"
  printf '%s %s\n' "$(L "Пароль:" "Password:")" "$CREATED_PASSWORD"
  printf 'SSL: sslmode=require\n'
  echo
  printf '%s\n' "$(L "Ссылка для подключения (для конфигурации проектов):" "Connection URL (for project configuration):")"
  printf '%s\n' "$url"
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

pkg_installed() { dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null | grep -qx installed; }

pgdg_repo_present() { grep -rqsE 'apt\.postgresql\.org' /etc/apt/sources.list /etc/apt/sources.list.d/; }

# Verifies each piece separately (prerequisites, PGDG repository, server package,
# cluster) and does only what is missing — safe to run after an interrupted install.
install_postgres() {
  export DEBIAN_FRONTEND=noninteractive
  local -a apt_opts=(-o DPkg::Lock::Timeout=120)
  local -a missing=()
  local p refreshed=0

  if [[ -n "$(dpkg --audit 2>/dev/null)" ]]; then
    run_step "$(L "Завершаю прерванную установку пакетов (dpkg --configure -a)" "Finishing an interrupted package installation (dpkg --configure -a)")" \
      dpkg --configure -a
  fi

  for p in curl ca-certificates gnupg lsb-release openssl postgresql-common; do
    if ! pkg_installed "$p"; then missing+=("$p"); fi
  done
  if (( ${#missing[@]} > 0 )); then
    run_step "$(L "Обновляю индекс пакетов" "Updating the package index")" apt-get "${apt_opts[@]}" update -qq
    refreshed=1
    run_step "$(L "Устанавливаю зависимости: ${missing[*]}" "Installing prerequisites: ${missing[*]}")" \
      apt-get "${apt_opts[@]}" install -y -qq "${missing[@]}"
  else
    skip "$(L "Зависимости уже установлены" "Prerequisites are already installed")"
  fi

  if pgdg_repo_present; then
    skip "$(L "Репозиторий PGDG уже подключён" "The PGDG repository is already configured")"
  else
    run_step "$(L "Подключаю репозиторий PGDG" "Adding the PGDG repository")" \
      /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
    refreshed=1
  fi

  if pkg_installed "postgresql-${PG_VERSION}"; then
    skip "$(L "Пакет postgresql-${PG_VERSION} уже установлен" "Package postgresql-${PG_VERSION} is already installed")"
  else
    if (( refreshed == 0 )); then
      run_step "$(L "Обновляю индекс пакетов" "Updating the package index")" apt-get "${apt_opts[@]}" update -qq
    fi
    run_step "$(L "Устанавливаю PostgreSQL ${PG_VERSION}" "Installing PostgreSQL ${PG_VERSION}")" \
      apt-get "${apt_opts[@]}" install -y -qq "postgresql-${PG_VERSION}"
  fi

  detect_cluster
  if [[ -z "$PG_VER" ]]; then
    warn "$(L "Пакет установлен, но кластер не создан (прерванная установка?) — создаю" "The package is installed but no cluster exists (interrupted install?) — creating it")"
    run_step "$(L "Создаю кластер ${PG_VERSION}/main" "Creating cluster ${PG_VERSION}/main")" pg_createcluster "$PG_VERSION" main --start
  fi
}

# If the service is up but not answering (e.g. the config was changed but the
# restart never happened), restart it once so the saved configuration is applied.
ensure_responding() {
  local i
  for i in 1 2 3 4 5; do
    if pg_isready -q; then return 0; fi
    sleep 1
  done
  warn "$(L "Сервис запущен, но не отвечает на порту ${PG_PORT} — перезапускаю (конфигурация могла не примениться)" "The service is up but not answering on port ${PG_PORT} — restarting it (the configuration may not have been applied)")"
  systemctl restart "$SVC"
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

  if [[ "$need_restart" == 0 && "$(psql_val 'SELECT count(*) FROM pg_settings WHERE pending_restart' 2>/dev/null || echo 0)" != 0 ]]; then
    info "$(L "Есть параметры, ожидающие перезапуска (прерванная настройка) — перезапускаю" "Some settings are waiting for a restart (interrupted setup) — restarting")"
    need_restart=1
  fi

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
  local ok=0 sysctl_conf="/etc/sysctl.d/99-pgmgr.conf"
  if [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; then
    skip "$(L "Swap уже активен" "Swap is already active")"
  elif [[ "$SWAP_GB" -gt 0 ]]; then
    if [[ -f /swapfile ]]; then
      warn "$(L "Найден неактивный /swapfile (вероятно, прерванная настройка) — активирую" "Found an inactive /swapfile (probably an interrupted setup) — activating it")"
      chmod 600 /swapfile
      if swapon /swapfile 2>/dev/null || { mkswap -f /swapfile >/dev/null && swapon /swapfile; }; then ok=1; fi
    elif fallocate -l "${SWAP_GB}G" /swapfile 2>/dev/null \
         && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile; then
      ok=1
    fi
    if [[ "$ok" == 1 ]]; then
      log "$(L "Swap включён (страховка от OOM)" "Swap enabled (OOM insurance)")"
    else
      warn "$(L "Не удалось создать swap (контейнерная виртуализация?) — пропускаю" "Could not create swap (container virtualization?) — skipping")"
    fi
  fi
  if [[ -f /swapfile ]] && ! grep -q '^/swapfile' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
  if [[ -f "$sysctl_conf" ]] && grep -qx 'vm.swappiness = 1' "$sysctl_conf"; then
    skip "$(L "vm.swappiness уже настроен" "vm.swappiness is already configured")"
  else
    printf 'vm.swappiness = 1\n' > "$sysctl_conf"
    log "$(L "vm.swappiness = 1" "vm.swappiness = 1")"
  fi
  sysctl -q -p "$sysctl_conf" >/dev/null || warn "$(L "sysctl не применён" "sysctl was not applied")"
}

step_backup() {
  local tmp cron_line changed=0
  install -d -o postgres -g postgres -m 700 "$BACKUP_DIR"
  tmp="$(mktemp)"
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
  } > "$tmp"
  if [[ -x "$BACKUP_BIN" ]] && cmp -s "$tmp" "$BACKUP_BIN"; then
    :
  else
    install -m 755 "$tmp" "$BACKUP_BIN"
    changed=1
  fi
  rm -f "$tmp"

  cron_line="0 3 * * * postgres ${BACKUP_BIN} >> ${BACKUP_DIR}/backup.log 2>&1"
  if [[ -f "$BACKUP_CRON" && "$(cat "$BACKUP_CRON")" == "$cron_line" ]]; then
    :
  else
    printf '%s\n' "$cron_line" > "$BACKUP_CRON"
    chmod 644 "$BACKUP_CRON"
    changed=1
  fi

  if [[ "$changed" == 1 ]]; then
    log "$(L "Бэкап: ежедневно в 03:00 -> $BACKUP_DIR (хранение ${BACKUP_RETENTION_DAYS} дн.). Копию вне сервера настройте отдельно (rclone/S3)." "Backup: daily at 03:00 -> $BACKUP_DIR (kept ${BACKUP_RETENTION_DAYS} days). Set up an off-server copy separately (rclone/S3).")"
  else
    skip "$(L "Бэкап уже настроен и актуален (03:00 -> $BACKUP_DIR)" "Backup is already configured and up to date (03:00 -> $BACKUP_DIR)")"
  fi
}

cmd_firewall_init() {
  ensure_running
  local sshp
  sshp="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"
  sshp="${sshp:-22}"
  warn "$(L "Будет включён ufw: deny incoming; разрешён SSH (порт $sshp, с ограничением частоты). Порт $PG_PORT — только для клиентов из выбранного режима сети и из access-add." "ufw will be enabled: deny incoming; SSH allowed (port $sshp, rate-limited). Port $PG_PORT — only for clients of the selected network mode and from access-add.")"
  confirm "$(L "Включить файрвол?" "Enable the firewall?")" || { log "$(L "Пропущено" "Skipped")"; return 0; }
  if pkg_installed ufw; then
    skip "$(L "ufw уже установлен" "ufw is already installed")"
  else
    run_step "$(L "Устанавливаю ufw" "Installing ufw")" \
      env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y -qq ufw
  fi
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
  local total="$SETUP_TOTAL" prev last a recheck=0
  require_root
  for a in "$@"; do
    case "$a" in --recheck|--force) recheck=1 ;; esac
  done
  prev="$(state_get SETUP_STATUS)"
  last="$(state_get SETUP_LAST_STEP)"

  # Already configured and running interactively: go straight to the management menu.
  if [[ "$recheck" == 0 && "$prev" == complete && "$INTERACTIVE" == 1 && "$ASSUME_YES" != 1 && -z "${PGMGR_FROM_MENU:-}" ]]; then
    detect_cluster
    if [[ -n "$PG_VER" ]]; then
      info "$(L "Сервер уже настроен — открываю меню управления. Полная повторная проверка: пункт «Первичная настройка / проверка» или '$SELF setup --recheck'." "The server is already set up — opening the management menu. For a full re-check use the \"Initial setup / re-check\" item or '$SELF setup --recheck'.")"
      sleep 1
      menu
      return 0
    fi
  fi
  if [[ "$prev" == interrupted || "$prev" == running ]]; then
    echo
    box_top "$(L "Возобновление настройки" "Resuming setup")" "$C_YELLOW"
    box_row "$(L "Предыдущий запуск не завершён (остановка на шаге ${last:-?} из ${total})." "The previous run did not finish (stopped at step ${last:-?} of ${total}).")"
    box_row "$(L "Проверяю, что уже сделано, пропускаю выполненное и продолжаю." "Checking what is already done, skipping it, and continuing.")"
    box_bottom
  fi
  SETUP_ACTIVE=1
  state_set SETUP_STATUS running
  step_header 1 "$total" "$(L "Анализ сервера" "Server analysis")"
  cmd_analyze

  step_header 2 "$total" "$(L "Установка и запуск PostgreSQL" "PostgreSQL installation and startup")"
  detect_cluster
  if [[ -n "$PG_VER" ]]; then
    skip "$(L "PostgreSQL ${PG_VER} (кластер ${PG_CLUSTER}, порт ${PG_PORT}) уже установлен" "PostgreSQL ${PG_VER} (cluster ${PG_CLUSTER}, port ${PG_PORT}) is already installed")"
  else
    install_postgres
    detect_cluster
    [[ -n "$PG_VER" ]] || die "$(L "Кластер PostgreSQL не найден после установки" "PostgreSQL cluster not found after installation")"
  fi

  if systemctl is-enabled --quiet postgresql 2>/dev/null; then
    skip "$(L "Автозапуск PostgreSQL уже включён" "PostgreSQL autostart is already enabled")"
  else
    systemctl enable postgresql >/dev/null 2>&1 || true
    log "$(L "Автозапуск PostgreSQL включён" "PostgreSQL autostart enabled")"
  fi
  if systemctl is-active --quiet "$SVC"; then
    skip "$(L "Сервис $SVC уже запущен" "Service $SVC is already running")"
    ensure_responding
  else
    warn "$(L "Сервис $SVC не запущен — запускаю" "Service $SVC is not running — starting it")"
    systemctl start "$SVC"
  fi
  wait_ready

  step_header 3 "$total" "$(L "Сеть и доступ" "Network and access")"
  select_network 0
  ensure_connect_host
  step_header 4 "$total" "$(L "Порт" "Port")"
  select_port 0
  select_nat 0
  step_port_config
  step_header 5 "$total" "$(L "Настройка под ваш сервер" "Tuning for your server")"
  step_tuning
  step_port_finish
  step_header 6 "$total" "$(L "Защита, swap" "Hardening and swap")"
  step_harden
  step_swap_sysctl
  step_header 7 "$total" "$(L "Резервные копии" "Backups")"
  step_backup

  step_header 8 "$total" "$(L "Файрвол и итоги" "Firewall and summary")"
  if ! ufw_active; then
    warn "$(L "Файрвол ufw не активен." "The ufw firewall is not active.")"
    if [[ -t 0 && "$ASSUME_YES" != 1 ]]; then
      if confirm "$(L "Настроить ufw сейчас?" "Set up ufw now?")"; then cmd_firewall_init; fi
    fi
  else
    apply_ufw_defaults
  fi

  print_network_summary
  echo
  box_top "$(L "Готово" "Done")" "$C_GREEN"
  box_row "$(L "Сервер PostgreSQL настроен и запущен." "The PostgreSQL server is set up and running.")" "$C_GREEN$C_BOLD"
  box_row "$(L "Дальше откроется меню управления. Позже: sudo $SELF" "The management menu opens next. Later: sudo $SELF")" "$C_DIM"
  box_bottom
  SETUP_ACTIVE=0
  state_set SETUP_STATUS complete
  state_set SETUP_LAST_STEP "$total"

  if [[ "$INTERACTIVE" == 1 && "$ASSUME_YES" != 1 && -z "${PGMGR_FROM_MENU:-}" ]]; then
    if [[ "$(psql_val "SELECT count(*) FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres'")" == 0 ]]; then
      if confirm "$(L "Создать первую БД и её владельца сейчас?" "Create the first database and its owner now?")"; then
        cmd_db_create
      fi
    fi
    # keep the last screen (e.g. the password) visible until the user is ready
    echo
    read -r -p "  $(L "Нажмите Enter, чтобы открыть меню управления…" "Press Enter to open the management menu…")" _ || true
    menu
    return 0
  fi
  if [[ -t 0 && "$ASSUME_YES" != 1 && -z "${PGMGR_FROM_MENU:-}" ]]; then
    if [[ "$(psql_val "SELECT count(*) FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres'")" == 0 ]]; then
      if confirm "$(L "Создать первую БД и её владельца сейчас?" "Create the first database and its owner now?")"; then
        cmd_db_create
        return 0
      fi
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
  section "$(L "Базы данных" "Databases")"
  psql_admin -d postgres -c "SELECT d.datname AS db, pg_get_userbyid(d.datdba) AS owner, pg_size_pretty(pg_database_size(d.datname)) AS size FROM pg_database d WHERE NOT d.datistemplate ORDER BY 1"
  section "$(L "Пользователи" "Users")"
  psql_admin -d postgres -c "SELECT rolname AS \"user\", rolcanlogin AS login, rolconnlimit AS conn_limit, rolsuper AS super FROM pg_roles WHERE rolname !~ '^pg_' AND rolname !~ '_(rw|ro)\$' ORDER BY 1"
  section "$(L "Профили (пользователь -> БД)" "Profiles (user -> database)")"
  psql_admin -d postgres -c "SELECT m.rolname AS \"user\", regexp_replace(g.rolname, '_(rw|ro)\$', '') AS db, CASE WHEN g.rolname ~ '_rw\$' THEN 'readwrite' ELSE 'readonly' END AS profile FROM pg_auth_members am JOIN pg_roles g ON g.oid = am.roleid JOIN pg_roles m ON m.oid = am.member WHERE g.rolname ~ '_(rw|ro)\$' AND EXISTS (SELECT 1 FROM pg_database d WHERE d.datname = regexp_replace(g.rolname, '_(rw|ro)\$', '')) UNION ALL SELECT pg_get_userbyid(datdba), datname, 'owner' FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres' ORDER BY 2, 1"
  section "$(L "Правила удалённого доступа (pg_hba, управляются скриптом)" "Remote access rules (pg_hba, managed by the script)")"
  grep "# ${TAG}:" "$(hba_file)" || echo "$(L "(нет)" "(none)")"
  print_network_summary
}

# ---- Server status: live load dashboard ------------------------------------------

HIST_N=14                     # points kept for every sparkline
H_CPU=(); H_LOAD=(); H_RAM=(); H_CONN=(); H_TPS=(); H_RX=(); H_TX=()
M_CPU=0; M_LOAD1="0.00"; M_LOAD5="0.00"; M_LOAD15="0.00"; M_LOADPCT=0
M_RAM_PCT=0; M_RAM_USED_MB=0; M_RAM_TOTAL_MB=0
M_SWAP_PCT=0; M_SWAP_USED_MB=0; M_SWAP_TOTAL_MB=0
M_DISK_PCT=0; M_DISK_USED_GB=0; M_DISK_TOTAL_GB=0
M_RX=0; M_TX=0
M_PG_UP=0; M_CONN=0; M_ACTIVE=0; M_MAXCONN=100; M_TPS=0; M_HIT=100; M_SIZE="-"; M_UPTIME=0; M_DBS=0
S_VERSION=""; S_UFW=""; S_BACKUP=""; S_SVC_STATE=""
CPU_PREV_T=0; CPU_PREV_I=0; NET_IF=""; NET_PREV_RX=0; NET_PREV_TX=0; NET_PREV_US=0
PG_PREV_X=0; PG_PREV_US=0

now_us() {
  if [[ -n "${EPOCHREALTIME:-}" ]]; then echo "${EPOCHREALTIME/./}"; else echo $(( $(date +%s) * 1000000 )); fi
}

hist_push() { # hist_push ARRAY value
  local -n __h="$1"
  __h+=("$2")
  if (( ${#__h[@]} > HIST_N )); then __h=("${__h[@]: -HIST_N}"); fi
}

# Sparkline of the last HIST_N values (right aligned). spark ARRAY [fixed_max]
spark() {
  local -n __a="$1"
  local fixed="${2:-0}" max=0 v i out="" idx pad
  local -a ch
  if [[ "$UTF" == 1 ]]; then ch=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █); else ch=(_ . - = + '*' '#' '@'); fi
  for v in "${__a[@]}"; do
    if (( v > max )); then max=$v; fi
  done
  if (( fixed > 0 )); then max=$fixed; fi
  if (( max < 1 )); then max=1; fi
  pad=$(( HIST_N - ${#__a[@]} ))
  if (( pad > 0 )); then out="$(rep ' ' "$pad")"; fi
  for v in "${__a[@]}"; do
    idx=$(( v * 7 / max ))
    if (( idx > 7 )); then idx=7; fi
    if (( idx < 0 )); then idx=0; fi
    out+="${ch[idx]}"
  done
  printf '%s' "$out"
}

# Colour by load: low = green, high = red (invert=1: high = good, e.g. cache hit ratio)
level_color() { # level_color percent [invert]
  local p="$1" inv="${2:-0}"
  if [[ "$inv" == 1 ]]; then
    if (( p >= 95 )); then printf '%s' "$C_GREEN"; elif (( p >= 85 )); then printf '%s' "$C_YELLOW"; else printf '%s' "$C_RED"; fi
  else
    if (( p < 60 )); then printf '%s' "$C_GREEN"; elif (( p < 85 )); then printf '%s' "$C_YELLOW"; else printf '%s' "$C_RED"; fi
  fi
}

gauge() { # gauge percent width [invert]
  local pct="$1" w="$2" inv="${3:-0}" filled full empty
  if (( pct < 0 )); then pct=0; fi
  if (( pct > 100 )); then pct=100; fi
  filled=$(( pct * w / 100 ))
  if [[ "$UTF" == 1 ]]; then full="█"; empty="░"; else full="#"; empty="."; fi
  printf '%s%s%s%s%s%s' "$(level_color "$pct" "$inv")" "$(rep "$full" "$filled")" "$C_RESET" "$C_DIM" "$(rep "$empty" $(( w - filled )))" "$C_RESET"
}

# One dashboard row: label, optional gauge, extra text, optional sparkline.
dash_row() { # dash_row "label" percent(-1 = no gauge) "extra" [ARRAY [spark_max [invert]]]
  local label="$1" pct="$2" extra="$3" arr="${4:-}" smax="${5:-0}" inv="${6:-0}" g pt sp=""
  if (( pct >= 0 )); then
    g="$(gauge "$pct" 16 "$inv")"
    pt="$(printf '%3d%%' "$pct")"
  else
    g="$(rep ' ' 16)"
    pt="    "
  fi
  if [[ -n "$arr" ]]; then sp="$(spark "$arr" "$smax")"; else sp="$(rep ' ' "$HIST_N")"; fi
  box_raw "$(padr "$label" 12) $g $pt  ${C_DIM}$(padr "$extra" 18)${C_RESET} ${C_CYAN}${sp}${C_RESET}"
}

fmt_uptime() { # seconds -> 3d 4h 12m
  local s="$1" d h m
  d=$(( s / 86400 )); h=$(( s % 86400 / 3600 )); m=$(( s % 3600 / 60 ))
  if (( d > 0 )); then printf '%s%s %s%s %s%s' "$d" "$(L "д" "d")" "$h" "$(L "ч" "h")" "$m" "$(L "м" "m")"
  elif (( h > 0 )); then printf '%s%s %s%s' "$h" "$(L "ч" "h")" "$m" "$(L "м" "m")"
  else printf '%s%s' "$m" "$(L "м" "m")"; fi
}

fmt_rate() { # KB/s -> "12 KB/s" or "1.4 MB/s"
  local k="$1"
  if (( k >= 1024 )); then printf '%s.%s MB/s' $(( k / 1024 )) $(( k % 1024 * 10 / 1024 )); else printf '%s KB/s' "$k"; fi
}

# ---- samplers -------------------------------------------------------------------

sample_system() {
  local u n s i io irq sirq st t dt di l1 l5 l15 mt ma st_t st_f now rx tx dtu iface
  # CPU
  read -r _ u n s i io irq sirq st _ < /proc/stat
  t=$(( u + n + s + i + io + irq + sirq + st ))
  dt=$(( t - CPU_PREV_T )); di=$(( i + io - CPU_PREV_I ))
  if (( dt > 0 && CPU_PREV_T > 0 )); then M_CPU=$(( (dt - di) * 100 / dt )); fi
  CPU_PREV_T=$t; CPU_PREV_I=$(( i + io ))
  # load average (relative to cores)
  read -r l1 l5 l15 _ < /proc/loadavg
  M_LOAD1="$l1"; M_LOAD5="$l5"; M_LOAD15="$l15"
  M_LOADPCT=$(( (10#${l1%.*} * 100 + 10#${l1#*.}) / (HW_CORES > 0 ? HW_CORES : 1) ))
  # memory and swap
  read -r mt ma st_t st_f < <(awk '/^MemTotal:/{a=$2} /^MemAvailable:/{b=$2} /^SwapTotal:/{c=$2} /^SwapFree:/{d=$2} END{print a, b, c, d}' /proc/meminfo)
  M_RAM_TOTAL_MB=$(( mt / 1024 )); M_RAM_USED_MB=$(( (mt - ma) / 1024 ))
  M_RAM_PCT=$(( mt > 0 ? (mt - ma) * 100 / mt : 0 ))
  M_SWAP_TOTAL_MB=$(( st_t / 1024 )); M_SWAP_USED_MB=$(( (st_t - st_f) / 1024 ))
  M_SWAP_PCT=$(( st_t > 0 ? (st_t - st_f) * 100 / st_t : 0 ))
  # disk of the data directory
  read -r dt di < <(df -k --output=size,used "${HW_DISK_PATH:-/}" 2>/dev/null | awk 'NR==2{print $1, $2}')
  dt="${dt//[!0-9]/}"; di="${di//[!0-9]/}"; dt="${dt:-0}"; di="${di:-0}"
  M_DISK_TOTAL_GB=$(( dt / 1048576 )); M_DISK_USED_GB=$(( di / 1048576 ))
  M_DISK_PCT=$(( dt > 0 ? di * 100 / dt : 0 ))
  # network (default route interface)
  if [[ -z "$NET_IF" ]]; then
    iface="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}')"
    NET_IF="${iface:-none}"
  fi
  if [[ -r "/sys/class/net/${NET_IF}/statistics/rx_bytes" ]]; then
    now="$(now_us)"
    rx="$(< "/sys/class/net/${NET_IF}/statistics/rx_bytes")"
    tx="$(< "/sys/class/net/${NET_IF}/statistics/tx_bytes")"
    dtu=$(( now - NET_PREV_US ))
    if (( NET_PREV_US > 0 && dtu > 0 )); then
      M_RX=$(( (rx - NET_PREV_RX) * 1000000 / dtu / 1024 ))
      M_TX=$(( (tx - NET_PREV_TX) * 1000000 / dtu / 1024 ))
    fi
    NET_PREV_RX=$rx; NET_PREV_TX=$tx; NET_PREV_US=$now
  fi
  hist_push H_CPU "$M_CPU"
  hist_push H_LOAD "$(( M_LOADPCT > 100 ? 100 : M_LOADPCT ))"
  hist_push H_RAM "$M_RAM_PCT"
  hist_push H_RX "$M_RX"
  hist_push H_TX "$M_TX"
}

sample_postgres() {
  local line conn active maxc xacts hit size up dbs now dtu
  M_PG_UP=0
  if [[ -z "$PG_VER" ]] || ! systemctl is-active --quiet "$SVC" 2>/dev/null; then return 0; fi
  line="$(psql_admin -At -F '|' -d postgres -c "SELECT (SELECT count(*) FROM pg_stat_activity WHERE backend_type='client backend'), (SELECT count(*) FROM pg_stat_activity WHERE backend_type='client backend' AND state='active'), current_setting('max_connections')::int, (SELECT COALESCE(sum(xact_commit + xact_rollback), 0) FROM pg_stat_database), (SELECT COALESCE(round(100.0 * sum(blks_hit) / NULLIF(sum(blks_hit) + sum(blks_read), 0)), 100) FROM pg_stat_database), (SELECT pg_size_pretty(COALESCE(sum(pg_database_size(datname)), 0)) FROM pg_database WHERE NOT datistemplate), EXTRACT(EPOCH FROM now() - pg_postmaster_start_time())::bigint, (SELECT count(*) FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres')" 2>/dev/null || true)"
  [[ -n "$line" ]] || return 0
  IFS='|' read -r conn active maxc xacts hit size up dbs <<<"$line"
  M_PG_UP=1; M_CONN="$conn"; M_ACTIVE="$active"; M_MAXCONN="$maxc"; M_HIT="$hit"; M_SIZE="$size"; M_UPTIME="$up"; M_DBS="$dbs"
  now="$(now_us)"
  dtu=$(( now - PG_PREV_US ))
  if (( PG_PREV_US > 0 && dtu > 0 )); then M_TPS=$(( (xacts - PG_PREV_X) * 1000000 / dtu )); fi
  PG_PREV_X="$xacts"; PG_PREV_US="$now"
  hist_push H_CONN "$M_CONN"
  hist_push H_TPS "$M_TPS"
}

status_static() { # slow-changing facts, collected once
  S_VERSION=""
  S_SVC_STATE="$(L "не установлен" "not installed")"
  if [[ -n "$PG_VER" ]]; then
    if systemctl is-active --quiet "$SVC" 2>/dev/null; then
      S_SVC_STATE="$(L "работает" "running")"
      S_VERSION="$(psql_val 'SHOW server_version' 2>/dev/null || true)"
      S_VERSION="${S_VERSION%% *}"
    else
      S_SVC_STATE="$(L "остановлен" "stopped")"
    fi
  fi
  if ufw_active; then S_UFW="$(L "включён" "enabled")"; else S_UFW="$(L "выключен" "disabled")"; fi
  S_BACKUP="$(find "$BACKUP_DIR" -name '*.dump' -printf '%TY-%Tm-%Td %TH:%TM\n' 2>/dev/null | sort | tail -n1 || true)"
  S_BACKUP="${S_BACKUP:-$(L "нет" "none")}"
}

# ---- rendering ------------------------------------------------------------------

render_status_frame() { # render_status_frame [live]
  local live="${1:-}" mode cport up_txt state_col conn_extra hit_int
  mode="$(state_get NETWORK_MODE)"
  cport="$(client_port)"
  if [[ "$live" == live ]]; then
    printf '\n  %s %s %s  %s%s%s\n' "$C_INV$C_CYAN" "$(L "Статус сервера" "Server status")" "$C_RESET" "$C_DIM" \
      "$(L "$(hostname) · обновление каждые 2 с · любая клавиша — выход" "$(hostname) · refresh every 2 s · any key to exit")" "$C_RESET"
  fi
  echo
  box_top "$(L "Нагрузка сервера" "Server load")" "$C_CYAN"
  dash_row "CPU" "$M_CPU" "$(L "$HW_CORES ядер" "$HW_CORES cores")" H_CPU 100
  dash_row "$(L "Нагрузка" "Load avg")" "$M_LOADPCT" "$M_LOAD1 $M_LOAD5 $M_LOAD15" H_LOAD 100
  dash_row "RAM" "$M_RAM_PCT" "$(gb "$M_RAM_USED_MB") / $(gb "$M_RAM_TOTAL_MB") GB" H_RAM 100
  dash_row "Swap" "$M_SWAP_PCT" "$(gb "$M_SWAP_USED_MB") / $(gb "$M_SWAP_TOTAL_MB") GB"
  dash_row "$(L "Диск" "Disk")" "$M_DISK_PCT" "$M_DISK_USED_GB / $M_DISK_TOTAL_GB GB"
  dash_row "$(L "Сеть ↓" "Net ↓")" -1 "$(fmt_rate "$M_RX")" H_RX
  dash_row "$(L "Сеть ↑" "Net ↑")" -1 "$(fmt_rate "$M_TX")" H_TX
  box_bottom

  echo
  if [[ "$M_PG_UP" == 1 ]]; then
    box_top "PostgreSQL" "$C_GREEN"
    conn_extra="$M_CONN / $M_MAXCONN · $(L "акт." "act.") $M_ACTIVE"
    dash_row "$(L "Подключения" "Connections")" "$(( M_MAXCONN > 0 ? M_CONN * 100 / M_MAXCONN : 0 ))" "$conn_extra" H_CONN "$M_MAXCONN"
    dash_row "$(L "Транзакции" "Transactions")" -1 "$M_TPS /s" H_TPS
    hit_int="${M_HIT%.*}"
    dash_row "Cache hit" "$hit_int" "$(L "попадания в кэш" "buffer cache")" "" 0 1
    up_txt="$(fmt_uptime "$M_UPTIME")"
    box_kv "$(L "Аптайм" "Uptime")" "$up_txt · $(L "БД" "DBs"): $M_DBS · $M_SIZE"
    box_bottom
  else
    box_top "PostgreSQL" "$C_RED"
    box_row "$(L "PostgreSQL: $S_SVC_STATE" "PostgreSQL: $S_SVC_STATE")" "$C_RED$C_BOLD"
    box_bottom
  fi

  echo
  box_top "$(L "Сервис и защита" "Service and protection")" "$C_MAGENTA"
  box_kv "$(L "Версия" "Version")" "${S_VERSION:-—} · ${PG_CLUSTER:-main} · $S_SVC_STATE"
  box_kv "$(L "Подключение" "Connect")" "$(connect_host):${cport} · TCP · ${mode:-—}"
  box_kv "$(L "Файрвол ufw" "Firewall ufw")" "$S_UFW"
  box_kv "$(L "Посл. бэкап" "Last backup")" "$S_BACKUP"
  box_bottom
}

status_prime() { # first samples so rates have a baseline, then a short warm-up history
  local i
  sample_system
  sleep 0.4
  for i in 1 2 3; do
    sample_system
    sample_postgres
    sleep 0.4
  done
}

status_live() {
  local frame k
  status_prime
  printf '\033[?25l\033[H\033[2J'
  while true; do
    sample_system
    sample_postgres
    frame="$(render_status_frame live)"
    printf '\033[H%s\n\033[J' "$frame"
    if read -rs -n1 -t 2 k; then break; fi
  done
  printf '\033[?25h'
}

cmd_status() {
  detect_cluster
  analyze_hardware      # cores, disk path etc. — the dashboard needs them
  status_static
  if [[ "$INTERACTIVE" == 1 && "$ASSUME_YES" != 1 ]]; then
    status_live
    return 0
  fi
  status_prime
  render_status_frame
  print_network_summary
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

  setup       [--recheck]                analyse the server, install, network mode, tuning (idempotent);
                                         on an already configured server it opens the menu (--recheck forces a full check)
  analyze                                cores / RAM / disk report
  network                                change network mode: local | private | public (list/all)
  port        [N|default|random]         change the port: 5432, custom or random free
  nat         [external_port|none]       server behind NAT: external port shown to clients
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

  setup       [--recheck]                анализ сервера, установка, режим сети, тюнинг (идемпотентно);
                                         на уже настроенном сервере открывает меню (--recheck — полная проверка)
  analyze                                анализ ядер / RAM / диска
  network                                сменить режим сети: local | private | public (list/all)
  port        [N|default|random]         сменить порт: 5432, свой или случайный свободный
  nat         [внешний_порт|none]        сервер за NAT: внешний порт для клиентов
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

# Menu definition (numbers are assigned automatically, in order).
# Group rows: "#|Русская группа|English group". Item rows: "command|Русский текст|English text".
# "@databases" opens the database browser (databases -> users -> connection details).
MENU_DEF=(
  "#|Сервер|Server"
  "setup|Первичная настройка / проверка|Initial setup / re-check"
  "status|Статус сервера|Server status"
  "analyze|Анализ сервера (ядра, RAM, диск)|Server analysis (cores, RAM, disk)"
  "network|Режим сети (local / private / public)|Network mode (local / private / public)"
  "port|Порт PostgreSQL|PostgreSQL port"
  "nat|Внешний порт и NAT|External port and NAT"
  "firewall-init|Файрвол ufw|Firewall (ufw)"
  "backup-now|Бэкап сейчас|Backup now"
  "#|Базы данных и пользователи|Databases and users"
  "@databases|Базы данных: просмотр и управление|Databases: browse and manage"
  "#|Прочее|Other"
  "lang|Язык сообщений (en / ru)|Message language (en / ru)"
)

menu_status_box() {
  local state color="$C_CYAN" dbs="" cport port_txt
  detect_cluster
  if [[ -z "$PG_VER" ]]; then
    state="$(L "не установлен" "not installed")"; color="$C_RED"
  elif systemctl is-active --quiet "$SVC"; then
    state="$(L "работает" "running")"; color="$C_GREEN"
    dbs="$(psql_val "SELECT count(*) FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres'" 2>/dev/null || true)"
  else
    state="$(L "остановлен" "stopped")"; color="$C_YELLOW"
  fi
  box_top "$(L "Состояние" "Status")" "$C_CYAN"
  box_kv "PostgreSQL" "${PG_VER:+$PG_VER · }$state" "$color$C_BOLD"
  if [[ -n "$PG_VER" ]]; then
    cport="$(client_port)"
    if [[ "$cport" != "$PG_PORT" ]]; then port_txt="$cport -> $PG_PORT (NAT)"; else port_txt="$PG_PORT"; fi
    box_kv "$(L "Порт" "Port")" "$port_txt · TCP"
    box_kv "$(L "Сеть" "Network")" "$(state_get NETWORK_MODE) · $(connect_host)"
    box_kv "$(L "Базы данных" "Databases")" "${dbs:-0}"
  fi
  box_kv "$(L "Язык" "Language")" "$LANG_UI"
  box_bottom
}


# ---- small UI helpers shared by all menu screens ---------------------------

menu_item() { # menu_item number "text"
  printf '    %s%3s%s  %s\n' "$C_CYAN$C_BOLD" "$1" "$C_RESET" "$2"
}

menu_back() { # menu_back ["label"]
  printf '\n    %s%3s%s  %s\n' "$C_RED$C_BOLD" "0" "$C_RESET" "${1:-$(L "Назад" "Back")}"
}

menu_prompt() { # menu_prompt VAR max -> reads a choice; returns 1 on end of input
  local __v="$1" __max="$2" __c=""
  echo
  read -r -p "  ${C_CYAN}${I_Q}${C_RESET} $(L "Выберите пункт" "Choose an item") ${C_DIM}[0-${__max}]${C_RESET}: " __c || return 1
  printf -v "$__v" '%s' "$__c"
}

menu_valid() { # menu_valid choice max  (1..max)
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= $2 ))
}

menu_run() { # run a command in a separate process (own screen), then wait for Enter
  PGMGR_FROM_MENU=1 "$SELF" "$@" || true
  pause_return
}

padr() { # padr "text" width  (character-based padding)
  local t="$1" w="$2" n
  n=$(( w - ${#t} ))
  if (( n < 0 )); then n=0; fi
  printf '%s%*s' "$t" "$n" ''
}

profile_color() { # colour for a profile name
  case "$1" in
    owner)     printf '%s' "$C_YELLOW$C_BOLD" ;;
    readwrite) printf '%s' "$C_GREEN" ;;
    readonly)  printf '%s' "$C_CYAN" ;;
    *)         printf '%s' "$C_DIM" ;;
  esac
}

# ---- data access (kept separate so the screens can be rendered with sample data) ----

menu_db_rows() { # name|owner|size|users
  psql_admin -At -F '|' -d postgres -c "SELECT d.datname, pg_get_userbyid(d.datdba), pg_size_pretty(pg_database_size(d.datname)), 1 + (SELECT count(*) FROM pg_auth_members am JOIN pg_roles g ON g.oid = am.roleid WHERE g.rolname IN (d.datname || '_rw', d.datname || '_ro')) FROM pg_database d WHERE NOT d.datistemplate AND d.datname <> 'postgres' ORDER BY 1" 2>/dev/null || true
}

menu_db_info() { # owner|size
  psql_admin -At -F '|' -d postgres -c "SELECT pg_get_userbyid(datdba), pg_size_pretty(pg_database_size(datname)) FROM pg_database WHERE datname='$1'" 2>/dev/null || true
}

menu_db_users() { # user|profile (owner first, then readwrite, then readonly)
  psql_admin -At -F '|' -d postgres -c "SELECT u, p FROM (SELECT pg_get_userbyid(datdba) AS u, 'owner' AS p, 0 AS o FROM pg_database WHERE datname='$1' UNION ALL SELECT m.rolname, CASE WHEN g.rolname='$1_rw' THEN 'readwrite' ELSE 'readonly' END, CASE WHEN g.rolname='$1_rw' THEN 1 ELSE 2 END FROM pg_auth_members am JOIN pg_roles g ON g.oid=am.roleid JOIN pg_roles m ON m.oid=am.member WHERE g.rolname IN ('$1_rw','$1_ro')) t ORDER BY o, u" 2>/dev/null || true
}

menu_user_profile() { # menu_user_profile db user -> owner|readwrite|readonly|none
  psql_val "SELECT COALESCE((SELECT 'owner' FROM pg_database WHERE datname='$1' AND pg_get_userbyid(datdba)='$2'), (SELECT CASE WHEN g.rolname='$1_rw' THEN 'readwrite' ELSE 'readonly' END FROM pg_auth_members am JOIN pg_roles g ON g.oid=am.roleid JOIN pg_roles m ON m.oid=am.member WHERE m.rolname='$2' AND g.rolname IN ('$1_rw','$1_ro') LIMIT 1), 'none')" 2>/dev/null || echo none
}

menu_user_limit() { psql_val "SELECT rolconnlimit FROM pg_roles WHERE rolname='$1'" 2>/dev/null || echo -1; }

menu_user_access() { # CIDRs allowed for a (db, user) pair, one per line
  local f
  f="$(hba_file 2>/dev/null || true)"
  if [[ -n "$f" ]]; then
    { grep "# ${TAG}:$1:$2\$" "$f" || true; } | awk '{print $4}'
  fi
}

# ---- Databases: list ------------------------------------------------------------

render_databases_screen() {
  local i=0 name owner size users
  DB_NAMES=()
  screen_begin "$(L "Базы данных" "Databases")"
  section "$(L "Все базы данных" "All databases")"
  printf '    %s%s%s\n' "$C_DIM" "$(padr "" 5)$(padr "$(L "БД" "Database")" 26)$(padr "$(L "Владелец" "Owner")" 24)$(padr "$(L "Размер" "Size")" 10)$(L "Польз." "Users")" "$C_RESET"
  while IFS='|' read -r name owner size users; do
    [[ -n "$name" ]] || continue
    i=$(( i + 1 ))
    DB_NAMES+=("$name")
    printf '    %s%3d%s  %s%s%s%s%s%s%s%s%s%s\n' "$C_CYAN$C_BOLD" "$i" "$C_RESET" \
      "$C_BOLD" "$(padr "$name" 26)" "$C_RESET" "$C_DIM" "$(padr "$owner" 24)$(padr "$size" 10)" "$C_RESET" \
      "$C_GREEN" "$users" "$C_RESET"
  done < <(menu_db_rows)
  if (( i == 0 )); then
    printf '    %s%s%s\n' "$C_DIM" "$(L "Баз данных пока нет." "No databases yet.")" "$C_RESET"
  fi
  DB_MAX=$(( i + 1 ))
  section "$(L "Действия" "Actions")"
  menu_item "$DB_MAX" "$(L "Создать новую БД" "Create a new database")"
  menu_back
}

screen_databases() {
  local choice
  while true; do
    render_databases_screen
    menu_prompt choice "$DB_MAX" || return 0
    if [[ -z "$choice" ]]; then continue; fi
    case "$choice" in 0|q|Q) return 0 ;; esac
    if ! menu_valid "$choice" "$DB_MAX"; then
      warn "$(L "Неизвестный пункт: $choice" "Unknown item: $choice")"; sleep 1; continue
    fi
    if (( choice == DB_MAX )); then
      menu_run db-create
    else
      screen_database "${DB_NAMES[choice-1]}"
    fi
  done
}

# ---- One database ----------------------------------------------------------------

render_database_screen() { # render_database_screen db
  local db="$1" owner size u p
  IFS='|' read -r owner size <<<"$(menu_db_info "$db")"
  screen_begin "$(L "База данных" "Database"): $db"
  echo
  box_top "$db" "$C_CYAN"
  box_kv "$(L "Владелец" "Owner")" "$owner"
  box_kv "$(L "Размер" "Size")" "$size"
  box_kv "$(L "Подключение" "Connect")" "$(connect_host):$(client_port) · TCP"
  box_bottom
  section "$(L "Пользователи" "Users")"
  while IFS='|' read -r u p; do
    [[ -n "$u" ]] || continue
    printf '    %s%s%s  %s%s%s%s\n' "$C_GREEN" "$I_DOT" "$C_RESET" "$(padr "$u" 30)" "$(profile_color "$p")" "$p" "$C_RESET"
  done < <(menu_db_users "$db")
  section "$(L "Действия" "Actions")"
  menu_item 1 "$(L "Создать нового пользователя" "Create a new user")"
  menu_item 2 "$(L "Выбрать существующего пользователя" "Select an existing user")"
  menu_item 3 "$(L "Удалить пользователя" "Delete a user")"
  menu_item 4 "$(L "Переименовать БД" "Rename the database")"
  menu_item 5 "$(L "Сменить владельца БД" "Change the database owner")"
  menu_item 6 "$(L "Удалить БД" "Drop the database")"
  menu_back
}

# Lets the user pick one of the database's users. -> PICKED_USER ('' = went back)
pick_db_user() { # pick_db_user db "title"
  local db="$1" title="$2" i u p choice
  local -a names
  PICKED_USER=""
  while true; do
    names=(); i=0
    screen_begin "$title: $db"
    section "$(L "Пользователи" "Users")"
    while IFS='|' read -r u p; do
      [[ -n "$u" ]] || continue
      i=$(( i + 1 ))
      names+=("$u")
      menu_item "$i" "$(padr "$u" 30)$(profile_color "$p")$p$C_RESET"
    done < <(menu_db_users "$db")
    if (( i == 0 )); then
      warn "$(L "У этой БД нет пользователей." "This database has no users.")"; sleep 1; return 1
    fi
    menu_back
    menu_prompt choice "$i" || return 1
    if [[ -z "$choice" ]]; then continue; fi
    case "$choice" in 0|q|Q) return 1 ;; esac
    if menu_valid "$choice" "$i"; then PICKED_USER="${names[choice-1]}"; return 0; fi
    warn "$(L "Неизвестный пункт: $choice" "Unknown item: $choice")"; sleep 1
  done
}

delete_db_user() { # delete_db_user db user
  local db="$1" u="$2" choice others
  others="$(user_databases "$u" 2>/dev/null || true)"
  while true; do
    screen_begin "$(L "Удаление пользователя" "Delete a user"): $u"
    echo
    info "$(L "Доступ пользователя '$u': $others" "Access of '$u': $others")"
    section "$(L "Что сделать" "What to do")"
    menu_item 1 "$(L "Отозвать доступ к БД '$db' (пользователь останется)" "Revoke access to '$db' (the user stays)")"
    menu_item 2 "$(L "Удалить пользователя полностью (со всех БД)" "Delete the user completely (from all databases)")"
    menu_back
    menu_prompt choice 2 || return 0
    if [[ -z "$choice" ]]; then continue; fi
    case "$choice" in
      0|q|Q) return 0 ;;
      1) menu_run user-role "$u" "$db" none; return 0 ;;
      2) menu_run user-drop "$u"; return 0 ;;
      *) warn "$(L "Неизвестный пункт: $choice" "Unknown item: $choice")"; sleep 1 ;;
    esac
  done
}

screen_database() { # screen_database db
  local db="$1" choice new
  while true; do
    db_exists "$db" || return 0
    render_database_screen "$db"
    menu_prompt choice 6 || return 0
    if [[ -z "$choice" ]]; then continue; fi
    case "$choice" in
      0|q|Q) return 0 ;;
      1) menu_run user-create "" "$db" ;;
      2) if pick_db_user "$db" "$(L "Выбор пользователя" "Select a user")"; then screen_user "$db" "$PICKED_USER"; fi ;;
      3) if pick_db_user "$db" "$(L "Удаление пользователя" "Delete a user")"; then delete_db_user "$db" "$PICKED_USER"; fi ;;
      4)
        new=""
        ask new "$(L "Новое имя БД" "New database name")" ""
        if [[ -n "$new" ]]; then
          menu_run db-rename "$db" "$new"
          if db_exists "$new"; then db="$new"; fi
        fi
        ;;
      5) menu_run db-chown "$db" ;;
      6) menu_run db-drop "$db" ;;
      *) warn "$(L "Неизвестный пункт: $choice" "Unknown item: $choice")"; sleep 1 ;;
    esac
  done
}

# ---- One user (connection details WITHOUT the password) --------------------------

render_user_screen() { # render_user_screen db user
  local db="$1" u="$2" host cport profile limit rules url masked
  host="$(connect_host)"
  cport="$(client_port)"
  profile="$(menu_user_profile "$db" "$u")"
  limit="$(menu_user_limit "$u")"
  rules="$(menu_user_access "$db" "$u" | paste -sd, - 2>/dev/null || true)"
  masked="$(rep "$I_DOT" 8)"
  screen_begin "$(L "Пользователь" "User"): $u"
  echo
  box_top "$(L "Данные для подключения" "Connection details")" "$C_GREEN"
  box_kv "IP" "$host"
  box_kv "$(L "Порт" "Port")" "$cport"
  box_kv "$(L "Протокол" "Protocol")" "TCP"
  box_kv "$(L "Название БД" "Database")" "$db"
  box_kv "$(L "Логин" "Login")" "$u"
  box_kv "$(L "Пароль" "Password")" "$masked $(L "(не хранится — сменить: пункт 1)" "(not stored — change: item 1)")" "$C_DIM"
  box_kv "SSL" "sslmode=require"
  box_bottom
  echo
  box_top "$(L "Права и доступ" "Permissions and access")" "$C_MAGENTA"
  box_kv "$(L "Профиль" "Profile")" "$profile" "$(profile_color "$profile")"
  if [[ "$limit" == "-1" ]]; then limit="$(L "без лимита" "unlimited")"; fi
  box_kv "$(L "Лимит подключ." "Conn. limit")" "$limit"
  box_kv "$(L "Доступ по IP" "IP access")" "${rules:-$(L "только локально" "local only")}"
  box_bottom

  url="postgresql://$(urlencode "$u"):PASSWORD@${host}:${cport}/${db}?sslmode=require"
  echo
  printf '%s\n' "$(L "Данные для копирования (без пароля):" "Copy-paste details (without the password):")"
  printf 'IP: %s\n' "$host"
  printf '%s %s\n' "$(L "Порт:" "Port:")" "$cport"
  printf '%s %s\n' "$(L "Протокол:" "Protocol:")" "TCP"
  printf '%s %s\n' "$(L "Название БД:" "Database:")" "$db"
  printf '%s %s\n' "$(L "Логин:" "Login:")" "$u"
  printf 'SSL: sslmode=require\n'
  printf '%s\n' "$(L "Ссылка (подставьте пароль):" "URL (insert the password):")"
  printf '%s\n' "$url"

  section "$(L "Действия" "Actions")"
  menu_item 1 "$(L "Сменить пароль" "Change the password")"
  menu_item 2 "$(L "Изменить профиль на этой БД" "Change the profile on this database")"
  menu_item 3 "$(L "Добавить IP-доступ" "Add IP access")"
  menu_item 4 "$(L "Убрать IP-доступ" "Remove IP access")"
  menu_item 5 "$(L "Лимит подключений" "Connection limit")"
  menu_item 6 "$(L "Переименовать пользователя" "Rename the user")"
  menu_item 7 "$(L "Удалить пользователя" "Delete the user")"
  menu_back
}

screen_user() { # screen_user db user
  local db="$1" u="$2" choice new
  while true; do
    role_exists "$u" || return 0
    render_user_screen "$db" "$u"
    menu_prompt choice 7 || return 0
    if [[ -z "$choice" ]]; then continue; fi
    case "$choice" in
      0|q|Q) return 0 ;;
      1) menu_run user-passwd "$u" ;;
      2) menu_run user-role "$u" "$db" ;;
      3) menu_run access-add "$db" "$u" ;;
      4) menu_run access-del "$db" "$u" ;;
      5) menu_run user-limit "$u" ;;
      6)
        new=""
        ask new "$(L "Новое имя пользователя" "New user name")" ""
        if [[ -n "$new" ]]; then
          menu_run user-rename "$u" "$new"
          if role_exists "$new"; then u="$new"; fi
        fi
        ;;
      7) menu_run user-drop "$u" ;;
      *) warn "$(L "Неизвестный пункт: $choice" "Unknown item: $choice")"; sleep 1 ;;
    esac
  done
}

# ---- Main menu ---------------------------------------------------------------------

render_menu() {
  local row cmd ru en n=0
  declare -gA MENU_CMDS=()
  screen_begin "$(L "Главное меню" "Main menu")"
  echo
  menu_status_box
  for row in "${MENU_DEF[@]}"; do
    IFS='|' read -r cmd ru en <<<"$row"
    if [[ "$cmd" == "#" ]]; then
      section "$(L "$ru" "$en")"
    else
      n=$(( n + 1 ))
      MENU_CMDS["$n"]="$cmd"
      menu_item "$n" "$(L "$ru" "$en")"
    fi
  done
  MENU_MAX="$n"
  menu_back "$(L "Выход" "Exit")"
}

menu() {
  local choice cmd
  while true; do
    render_menu
    menu_prompt choice "$MENU_MAX" || break
    if [[ -z "$choice" ]]; then continue; fi
    case "$choice" in
      0|q|Q|exit) break ;;
    esac
    cmd="${MENU_CMDS[$choice]:-}"
    if [[ -z "$cmd" ]]; then
      warn "$(L "Неизвестный пункт: $choice" "Unknown item: $choice")"
      sleep 1
      continue
    fi
    case "$cmd" in
      @databases) screen_databases ;;
      setup)      PGMGR_FROM_MENU=1 "$SELF" setup --recheck || true; pause_return ;;
      status)     PGMGR_FROM_MENU=1 "$SELF" status || true ;;
      lang)
        PGMGR_FROM_MENU=1 "$SELF" lang || true
        LANG_UI="$(state_get LANG_UI)"
        LANG_UI="${LANG_UI:-$(default_lang)}"
        pause_return
        ;;
      *)          menu_run "$cmd" ;;
    esac
  done
  clear_screen
  log "$(L "До свидания!" "Goodbye!")"
}


cmd_title() { # screen title for a command
  case "$1" in
    setup)         L "Первичная настройка" "Initial setup" ;;
    status)        L "Статус сервера" "Server status" ;;
    list)          L "БД, пользователи, профили" "Databases, users, profiles" ;;
    analyze)       L "Анализ сервера" "Server analysis" ;;
    network)       L "Режим сети" "Network mode" ;;
    port)          L "Порт PostgreSQL" "PostgreSQL port" ;;
    nat)           L "Внешний порт и NAT" "External port and NAT" ;;
    firewall-init) L "Файрвол ufw" "Firewall (ufw)" ;;
    backup-now)    L "Резервная копия" "Backup" ;;
    db-create)     L "Создание БД" "Create database" ;;
    db-drop)       L "Удаление БД" "Drop database" ;;
    db-rename)     L "Переименование БД" "Rename database" ;;
    db-chown)      L "Смена владельца БД" "Change database owner" ;;
    user-create)   L "Создание пользователя" "Create user" ;;
    user-role)     L "Профиль пользователя на БД" "User profile on a database" ;;
    user-passwd)   L "Смена пароля" "Change password" ;;
    user-rename)   L "Переименование пользователя" "Rename user" ;;
    user-limit)    L "Лимит подключений" "Connection limit" ;;
    user-drop)     L "Удаление пользователя" "Drop user" ;;
    access-add)    L "Добавить IP-доступ" "Add IP access" ;;
    access-del)    L "Убрать IP-доступ" "Remove IP access" ;;
    lang)          L "Язык сообщений" "Message language" ;;
    *)             printf '%s' "$1" ;;
  esac
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
    menu|help|usage) ;;
    status) if [[ "$INTERACTIVE" != 1 || "$ASSUME_YES" == 1 ]]; then screen_begin "$(cmd_title "$cmd")"; fi ;;
    *) screen_begin "$(cmd_title "$cmd")" ;;
  esac
  case "$cmd" in
    menu)          menu ;;
    setup)         cmd_setup "$@" ;;
    analyze)       cmd_analyze "$@" ;;
    network)       cmd_network "$@" ;;
    port)          cmd_port "$@" ;;
    nat)           cmd_nat "$@" ;;
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
