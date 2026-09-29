#!/usr/bin/env bash
# Prints one demo screen of pg_server_setup.sh with sample data (no real server needed).
# Usage: demo_screens.sh <ru|en> <menu|setup|resume|network|creds>
# Used by render_screens.sh to produce the README screenshots.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LANG_CHOICE="${1:?language: ru|en}"
SCREEN="${2:?screen: menu|setup|resume|network|creds}"

export PGMGR_FORCE_UI=1 TERM=xterm-256color LANG=en_US.UTF-8
# shellcheck source=../pg_server_setup.sh
source "$ROOT/pg_server_setup.sh"
set +eu
trap - ERR EXIT

LANG_UI="$LANG_CHOICE"

# ---- sample data instead of a real server --------------------------------
hostname() { echo pg-server-01; }
detect_cluster() { PG_VER=17; PG_CLUSTER=main; PG_PORT=5432; SVC=postgresql@17-main; }
systemctl() { return 0; }
psql_val() { echo 3; }
state_get() {
  case "$1" in
    NETWORK_MODE)  echo public ;;
    LISTEN_ADDR)   echo "localhost,203.0.113.9" ;;
    ACCESS_POLICY) echo list ;;
    DEFAULT_CIDRS) echo "203.0.113.10/32,198.51.100.0/24" ;;
    LANG_UI)       echo "$LANG_CHOICE" ;;
    SETUP_LAST_STEP) echo 5 ;;
    EXTERNAL_PORT) echo 37412 ;;
  esac
}
PG_PORT=5432
HW_CORES=2; HW_MEM_MB=3900; HW_AVAIL_MB=3420; HW_SWAP_MB=2048
HW_DISK_FREE_GB=54; HW_DISK_TOTAL_GB=58; HW_DISK_PATH=/var/lib/postgresql
HW_STORAGE_DETECTED=ssd; HW_VIRT=kvm; STORAGE=ssd

screen_menu() {
  render_menu
  printf '
  %s%s%s %s %s[0-%s]%s: 9
' "$C_CYAN" "$I_Q" "$C_RESET" "$(L "Выберите пункт" "Choose an item")" "$C_DIM" "$MENU_MAX" "$C_RESET"
}

screen_setup() {
  screen_begin "$(cmd_title setup)"
  step_header 1 8 "$(L "Анализ сервера" "Server analysis")"
  print_hw_report
  step_header 2 8 "$(L "Установка и запуск PostgreSQL" "PostgreSQL installation and startup")"
  run_step_static "$(L "Обновляю индекс пакетов" "Updating the package index")"
  run_step_static "$(L "Устанавливаю PostgreSQL 17" "Installing PostgreSQL 17")"
  log "$(L "Автозапуск PostgreSQL включён" "PostgreSQL autostart enabled")"
  log "$(L "Сервис postgresql@17-main запущен" "Service postgresql@17-main is running")"
  step_header 3 8 "$(L "Сеть и доступ" "Network and access")"
  log "$(L "Сеть: режим=public, доступ=list 203.0.113.10/32,198.51.100.0/24" "Network: mode=public, access=list 203.0.113.10/32,198.51.100.0/24")"
  step_header 4 8 "$(L "Порт" "Port")"
  log "$(L "Выбран порт PostgreSQL: 5432" "PostgreSQL port selected: 5432")"
  step_header 5 8 "$(L "Настройка под ваш сервер" "Tuning for your server")"
  log "$(L "Записаны настройки под этот сервер" "Settings for this server written")"
  printf '      %s\n' "listen_addresses = 'localhost,203.0.113.9'" "max_connections = 100" \
    "shared_buffers = 975MB" "effective_cache_size = 2925MB" "work_mem = 9MB" "max_parallel_workers = 2"
  log "$(L "Перезапускаю PostgreSQL для применения настроек" "Restarting PostgreSQL to apply settings")"
}

# static look of a finished run_step (the real one animates a spinner)
run_step_static() { log "$1"; }

screen_resume() {
  screen_begin "$(cmd_title setup)"
  echo
  box_top "$(L "Возобновление настройки" "Resuming setup")" "$C_YELLOW"
  box_row "$(L "Предыдущий запуск не завершён (остановка на шаге 5 из 8)." "The previous run did not finish (stopped at step 5 of 8).")"
  box_row "$(L "Проверяю, что уже сделано, пропускаю выполненное и продолжаю." "Checking what is already done, skipping it, and continuing.")"
  box_bottom
  step_header 2 8 "$(L "Установка и запуск PostgreSQL" "PostgreSQL installation and startup")"
  skip "$(L "Зависимости уже установлены" "Prerequisites are already installed")"
  skip "$(L "Репозиторий PGDG уже подключён" "The PGDG repository is already configured")"
  skip "$(L "Пакет postgresql-17 уже установлен" "Package postgresql-17 is already installed")"
  skip "$(L "Автозапуск PostgreSQL уже включён" "PostgreSQL autostart is already enabled")"
  skip "$(L "Сервис postgresql@17-main уже запущен" "Service postgresql@17-main is already running")"
  step_header 5 8 "$(L "Настройка под ваш сервер" "Tuning for your server")"
  info "$(L "Есть параметры, ожидающие перезапуска (прерванная настройка) — перезапускаю" "Some settings are waiting for a restart (interrupted setup) — restarting")"
  step_header 6 8 "$(L "Защита, swap" "Hardening and swap")"
  warn "$(L "Найден неактивный /swapfile (вероятно, прерванная настройка) — активирую" "Found an inactive /swapfile (probably an interrupted setup) — activating it")" 2>&1
  log "$(L "Swap включён (страховка от OOM)" "Swap enabled (OOM insurance)")"
  step_header 7 8 "$(L "Резервные копии" "Backups")"
  skip "$(L "Бэкап уже настроен и актуален (03:00 -> /var/backups/postgresql)" "Backup is already configured and up to date (03:00 -> /var/backups/postgresql)")"
}

screen_network() {
  screen_begin "$(cmd_title network)"
  print_network_summary
  echo
  box_top "$(L "Готово" "Done")" "$C_GREEN"
  box_row "$(L "Сервер PostgreSQL настроен и запущен." "The PostgreSQL server is set up and running.")" "$C_GREEN$C_BOLD"
  box_row "$(L "Дальше откроется меню управления. Позже: sudo ./pg_server_setup.sh" "The management menu opens next. Later: sudo ./pg_server_setup.sh")" "$C_DIM"
  box_bottom
}

screen_creds() {
  screen_begin "$(cmd_title db-create)"
  echo
  log "$(L "Создан пользователь 'myproject_owner'" "User 'myproject_owner' created")"
  log "$(L "Создана БД 'myproject_db' (владелец 'myproject_owner')" "Database 'myproject_db' created (owner 'myproject_owner')")"
  log "$(L "pg_hba: разрешён myproject_owner к myproject_db с 203.0.113.10/32" "pg_hba: allowed myproject_owner to myproject_db from 203.0.113.10/32")"
  CREATED_PASSWORD="3f9a1c7e5b2d80461a9e0c7d4b5f2e83"
  show_credentials myproject_owner myproject_db
}

# ---- sample data for the database browser screens --------------------------
menu_db_rows() {
  printf '%s
' "calculate_db|calculate_owner|84 MB|3" "shop_db|shop_owner|1240 MB|2" "blog_db|blog_owner|9 MB|2"
}
menu_db_info() { echo "calculate_owner|84 MB"; }
menu_db_users() { printf '%s
' "calculate_owner|owner" "calculate_app|readwrite" "calculate_report|readonly"; }
menu_user_profile() { echo readwrite; }
menu_user_limit() { echo 20; }
menu_user_access() { printf '%s
' "203.0.113.10/32" "198.51.100.0/24"; }

demo_prompt() { # demo_prompt max value
  printf '
  %s%s%s %s %s[0-%s]%s: %s
' "$C_CYAN" "$I_Q" "$C_RESET" "$(L "Выберите пункт" "Choose an item")" "$C_DIM" "$1" "$C_RESET" "$2"
}

screen_databases() {
  render_databases_screen
  demo_prompt "$DB_MAX" 1
}

screen_database() {
  render_database_screen calculate_db
  demo_prompt 6 2
}

screen_user() {
  render_user_screen calculate_db calculate_app
  demo_prompt 7 1
}

"screen_${SCREEN}"
