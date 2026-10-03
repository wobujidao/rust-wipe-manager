#!/bin/bash
# ============================================================================
# Rust Wipe Manager
# https://github.com/wobujidao/rust-wipe-manager
# ============================================================================

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# LGSM's find calls fail if the inherited cwd is unreadable (sudo -u from another home)
cd "$SCRIPT_DIR" || exit 1
CONFIG_FILE="$SCRIPT_DIR/config.env"
SECRETS_FILE="$SCRIPT_DIR/.secrets.env"

[ -f "$CONFIG_FILE" ] || { echo "ERROR: $CONFIG_FILE not found"; exit 1; }
[ -f "$SECRETS_FILE" ] || { echo "ERROR: $SECRETS_FILE not found"; exit 1; }
source "$CONFIG_FILE"
source "$SECRETS_FILE"

# Defaults for settings added after the first release, so an older config.env keeps working
: "${MESSAGES_LANG:=en}"
: "${SYSTEM_UPDATE_ENABLED:=false}"
: "${REBOOT_IF_REQUIRED:=false}"
: "${DAILY_RESTART_TIME:=04:30}"
: "${MAPWIPE_ENABLED:=false}"
: "${MAPWIPE_DAY:=5}"
: "${MAPWIPE_TIME:=19:00}"
: "${MAPWIPE_INTERVAL_WEEKS:=1}"
: "${MAPWIPE_MONTH_DAYS:=}"
: "${MAPWIPE_OPEN_TIME:=}"
: "${FULLWIPE_OPEN_TIME:=}"
: "${WIPETIMER_ENABLED:=false}"
: "${OXIDE_CHECK_ENABLED:=true}"
: "${OXIDE_LOAD_TIMEOUT:=900}"
: "${WATCHDOG_ENABLED:=true}"
: "${WATCHDOG_GRACE:=1800}"
: "${WATCHDOG_HANG_CHECKS:=5}"
: "${WATCHDOG_MAX_RESTARTS:=3}"
: "${LOG_KEEP_DAYS:=30}"
: "${LGSM_LOCK_DIR:=$(dirname "$LGSM_SCRIPT")/lgsm/lock}"
: "${LGSM_SELFNAME:=$(basename "$LGSM_SCRIPT")}"

LOCK_FILE="$SCRIPT_DIR/.manager.lock"
STATE_DIR="$SCRIPT_DIR/.state"
mkdir -p "$LOG_DIR" "$STATE_DIR"
LOG_FILE="$LOG_DIR/manager-$(date +%Y%m%d).log"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

# ----------------------------------------------------------------------------
# Telegram texts. Local variables of the caller (countdown, reason, ...) are
# visible here through bash dynamic scoping.
# ----------------------------------------------------------------------------
msg() {
    local key="$1"
    if [[ "$MESSAGES_LANG" == "ru" ]]; then
        case "$key" in
            already_stopped)   echo "ℹ️ $SERVER_TAG: сервер уже остановлен" ;;
            rcon_sent)         echo "📡 $SERVER_TAG: команда рестарта отправлена (отсчёт $((countdown/60)) мин, причина: $reason)" ;;
            rcon_error)        echo "❌ $SERVER_TAG: не удалось отправить RCON-команду" ;;
            server_stopped)    echo "🛑 $SERVER_TAG: сервер остановлен" ;;
            force_stop)        echo "⚠️ $SERVER_TAG: сервер не остановился сам, останавливаю принудительно" ;;
            start_timeout)     echo "❌ $SERVER_TAG: сервер не запустился за $((SERVER_START_TIMEOUT/60)) мин" ;;
            waiting_update)    echo "⏳ $SERVER_TAG: жду обновление Rust от Facepunch..." ;;
            update_detected)   echo "🎉 $SERVER_TAG: обновление Rust вышло (ждал $((elapsed/60)) мин)" ;;
            update_timeout)    echo "🚨 $SERVER_TAG: обновление Rust не вышло за $((max_wait/60)) мин. Вайп отменён, нужен человек!" ;;
            rust_updated)      echo "✅ $SERVER_TAG: Rust обновлён" ;;
            rust_update_error) echo "❌ $SERVER_TAG: ошибка обновления Rust" ;;
            oxide_updated)     echo "✅ $SERVER_TAG: Oxide обновлён" ;;
            oxide_update_error) echo "❌ $SERVER_TAG: ошибка обновления Oxide" ;;
            os_updated)        echo "✅ $SERVER_TAG: обновления системы установлены" ;;
            os_update_error)   echo "❌ $SERVER_TAG: ошибка обновления системы" ;;
            poweroff_once)     echo "⏻ $SERVER_TAG: VM выключается для обслуживания хоста, хост включит её сам" ;;
            rebooting)         echo "🔁 $SERVER_TAG: системе нужна перезагрузка, перезагружаю VM (сервер стартует при загрузке)" ;;
            booted_ok)         echo "✅ $SERVER_TAG: VM загрузилась, сервер запущен (ядро $(uname -r))" ;;
            booted_fail)       echo "❌ $SERVER_TAG: VM загрузилась, но сервер не запустился за $((SERVER_START_TIMEOUT/60)) мин" ;;
            restart_skip)      echo "ℹ️ $SERVER_TAG: сегодня полный вайп, ежедневный рестарт пропускаю" ;;
            restart_started)   echo "🛠 $SERVER_NAME: ежедневный рестарт (отсчёт $((DAILY_RESTART_COUNTDOWN/60)) мин)" ;;
            restart_done)      echo "✅ $SERVER_TAG: ежедневный рестарт завершён" ;;
            wipe_today)        echo "🕐 $SERVER_TAG: сегодня $wipe_name. Подготовка через $((sleep_for/60)) мин" ;;
            wipe_prep)         echo "🔥 $SERVER_NAME: начинаю $wipe_name" ;;
            wipe_abort_update) echo "🚨 $SERVER_TAG: Rust не обновился, $wipe_name отменён" ;;
            wipe_running)      echo "🗑 $SERVER_TAG: $wipe_name ($wipe_what)" ;;
            wipe_done)         echo "✅ $SERVER_TAG: $wipe_name выполнен" ;;
            wipe_error)        echo "❌ $SERVER_TAG: ошибка: $wipe_name не выполнен" ;;
            wipe_live)         echo "🎉 $SERVER_NAME: НОВЫЙ ВАЙП! Сервер обновлён и запущен (seed $(current_seed))" ;;
            gate_closed)       echo "⏳ $SERVER_TAG: сервер готов, игроки ждут в очереди до $open_at" ;;
            gate_opened)       echo "🚪 $SERVER_TAG: сервер открыт, очередь заходит (слотов: $max)" ;;
            not_ready)         echo "⚠️ $SERVER_TAG: сервер запущен, но RCON не отвечает уже $((OXIDE_LOAD_TIMEOUT/60)) мин. Oxide не проверен" ;;
            oxide_rollback)    echo "⚠️ $SERVER_TAG: Oxide не загрузился ($why). Откатываю Managed/ на копию до обновления Oxide" ;;
            oxide_rolled_back) echo "✅ $SERVER_TAG: откат сделан, сервер запущен. Если обновлялся сам Rust, копия без Oxide: плагины не работают до выхода исправления uMod" ;;
            oxide_rollback_fail) echo "🚨 $SERVER_TAG: откат Oxide не помог, нужен человек!" ;;
            oxide_no_backup)   echo "🚨 $SERVER_TAG: Oxide не загрузился ($why), а копии Managed/ нет. Нужен человек!" ;;
            wd_crashed)        echo "💥 $SERVER_TAG: сервер упал, перезапускаю" ;;
            wd_hung)           echo "🧊 $SERVER_TAG: сервер завис (RCON молчит $WATCHDOG_HANG_CHECKS проверки подряд), перезапускаю" ;;
            wd_restarted)      echo "✅ $SERVER_TAG: сервер перезапущен сторожем" ;;
            wd_restart_fail)   echo "❌ $SERVER_TAG: сторож не смог запустить сервер" ;;
            wd_give_up)        echo "🚨 $SERVER_TAG: сервер падает слишком часто ($WATCHDOG_MAX_RESTARTS перезапуска за час). Сторож остановился, нужен человек!" ;;
            busy)              echo "⚠️ $SERVER_TAG: manager.sh уже работает, второй запуск ($MODE) отменён" ;;
            test)              echo "🧪 $SERVER_TAG: проверка уведомлений Telegram" ;;
        esac
    else
        case "$key" in
            already_stopped)   echo "ℹ️ $SERVER_TAG: Server already stopped" ;;
            rcon_sent)         echo "📡 $SERVER_TAG: RCON sent (countdown $((countdown/60)) min, reason: $reason)" ;;
            rcon_error)        echo "❌ $SERVER_TAG: RCON send error" ;;
            server_stopped)    echo "🛑 $SERVER_TAG: Server stopped" ;;
            force_stop)        echo "⚠️ $SERVER_TAG: Force stop" ;;
            start_timeout)     echo "❌ $SERVER_TAG: Server did not start in $((SERVER_START_TIMEOUT/60)) min" ;;
            waiting_update)    echo "⏳ $SERVER_TAG: Waiting for Rust update from Facepunch..." ;;
            update_detected)   echo "🎉 $SERVER_TAG: Rust update detected after $((elapsed/60)) min wait" ;;
            update_timeout)    echo "🚨 $SERVER_TAG: TIMEOUT! Rust update did not appear in $((max_wait/60)) min. Manual intervention required!" ;;
            rust_updated)      echo "✅ $SERVER_TAG: Rust updated" ;;
            rust_update_error) echo "❌ $SERVER_TAG: Rust update error" ;;
            oxide_updated)     echo "✅ $SERVER_TAG: Oxide updated" ;;
            oxide_update_error) echo "❌ $SERVER_TAG: Oxide update error" ;;
            os_updated)        echo "✅ $SERVER_TAG: OS updates installed" ;;
            os_update_error)   echo "❌ $SERVER_TAG: OS update error" ;;
            poweroff_once)     echo "⏻ $SERVER_TAG: VM powering off for host maintenance, the host will start it again" ;;
            rebooting)         echo "🔁 $SERVER_TAG: OS update needs a reboot, rebooting VM (server starts on boot)" ;;
            booted_ok)         echo "✅ $SERVER_TAG: VM booted, server is up (kernel $(uname -r))" ;;
            booted_fail)       echo "❌ $SERVER_TAG: VM booted, but the server did not start in $((SERVER_START_TIMEOUT/60)) min" ;;
            restart_skip)      echo "ℹ️ $SERVER_TAG: Skipping daily restart, today is Full Wipe day" ;;
            restart_started)   echo "🛠 $SERVER_NAME: Daily restart started (countdown $((DAILY_RESTART_COUNTDOWN/60)) min)" ;;
            restart_done)      echo "✅ $SERVER_TAG: Daily restart completed successfully" ;;
            wipe_today)        echo "🕐 $SERVER_TAG: $wipe_name today. Preparation in $((sleep_for/60)) min" ;;
            wipe_prep)         echo "🔥 $SERVER_NAME: $wipe_name PREPARATION STARTED" ;;
            wipe_abort_update) echo "🚨 $SERVER_TAG: Rust update failed, aborting $wipe_name" ;;
            wipe_running)      echo "🗑 $SERVER_TAG: Performing $wipe_name ($wipe_what)" ;;
            wipe_done)         echo "✅ $SERVER_TAG: $wipe_name completed" ;;
            wipe_error)        echo "❌ $SERVER_TAG: $wipe_name error" ;;
            wipe_live)         echo "🎉 $SERVER_NAME: NEW WIPE IS LIVE! Server updated and ready (seed $(current_seed))" ;;
            gate_closed)       echo "⏳ $SERVER_TAG: server ready, players wait in the queue until $open_at" ;;
            gate_opened)       echo "🚪 $SERVER_TAG: server open, the queue is joining ($max slots)" ;;
            not_ready)         echo "⚠️ $SERVER_TAG: Server started, but RCON has not answered for $((OXIDE_LOAD_TIMEOUT/60)) min. Oxide not checked" ;;
            oxide_rollback)    echo "⚠️ $SERVER_TAG: Oxide did not load ($why). Rolling Managed/ back to the copy taken before the Oxide update" ;;
            oxide_rolled_back) echo "✅ $SERVER_TAG: Rolled back, server is running. If Rust itself was updated, that copy has no Oxide: plugins are off until uMod ships a fix" ;;
            oxide_rollback_fail) echo "🚨 $SERVER_TAG: Oxide rollback did not help. Manual intervention required!" ;;
            oxide_no_backup)   echo "🚨 $SERVER_TAG: Oxide did not load ($why) and there is no Managed/ backup. Manual intervention required!" ;;
            wd_crashed)        echo "💥 $SERVER_TAG: Server crashed, restarting" ;;
            wd_hung)           echo "🧊 $SERVER_TAG: Server hung (RCON silent for $WATCHDOG_HANG_CHECKS checks in a row), restarting" ;;
            wd_restarted)      echo "✅ $SERVER_TAG: Server restarted by the watchdog" ;;
            wd_restart_fail)   echo "❌ $SERVER_TAG: Watchdog could not start the server" ;;
            wd_give_up)        echo "🚨 $SERVER_TAG: Server keeps crashing ($WATCHDOG_MAX_RESTARTS restarts within an hour). Watchdog stopped, manual intervention required!" ;;
            busy)              echo "⚠️ $SERVER_TAG: manager.sh is already running, second run ($MODE) cancelled" ;;
            test)              echo "🧪 $SERVER_TAG: Telegram notification test" ;;
        esac
    fi
}

send_telegram() {
    local message="$1"
    local level="${2:-full}"
    log "[Telegram] $message"
    [[ "$ENABLE_TELEGRAM" != "true" ]] && return 0
    [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]] && return 0
    case "$TELEGRAM_LOG_LEVEL" in
        "full") ;;
        "success_error") [[ "$level" == "success" || "$level" == "error" ]] || return 0 ;;
        "error_only") [[ "$level" == "error" ]] || return 0 ;;
    esac
    # Plain text, URL-encoded: a raw "+" would arrive as a space, "_" would break Markdown
    local response
    response=$(curl -s --max-time 15 -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
        --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "text=$message" 2>&1)
    if [[ $? -ne 0 || ! "$response" =~ \"ok\":true ]]; then
        log "Telegram send error: $response"
        return 1
    fi
    return 0
}

# Only one maintenance run at a time. LGSM and rcon are started with fd 9 closed
# (see lgsm/rcon_command), so the lock dies with this process, not with tmux.
acquire_lock() {
    local quiet="${1:-}"
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        [[ "$quiet" == "quiet" ]] && exit 0
        log "Another manager.sh run holds the lock, exiting ($MODE)"
        send_telegram "$(msg busy)" "error"
        exit 1
    fi
}

lgsm() {
    "$LGSM_SCRIPT" "$@" 9>&-
}

cleanup_logs() {
    find "$LOG_DIR" -maxdepth 1 -name 'manager-*.log' -mtime +"$LOG_KEEP_DAYS" -delete 2>/dev/null
    local cron_log="$LOG_DIR/cron.log"
    if [ -f "$cron_log" ] && [ "$(stat -c %s "$cron_log")" -gt 10485760 ]; then
        mv -f "$cron_log" "$cron_log.1"
    fi
}

is_server_running() {
    pgrep -x RustDedicated >/dev/null
}

is_first_thursday() {
    local day=$(date +%d)
    local dow=$(date +%u)
    [[ "$dow" == "4" && "$day" -ge 1 && "$day" -le 7 ]]
}

current_seed() {
    cat "$(dirname "$LGSM_SCRIPT")/lgsm/data/$LGSM_SELFNAME-seed.txt" 2>/dev/null || echo "?"
}

rcon_command() {
    local cmd="$1"
    if [ ! -x "$RCON_CLI" ]; then
        log "ERROR: rcon-cli not found: $RCON_CLI"
        return 1
    fi
    "$RCON_CLI" -a "$RCON_HOST:$RCON_PORT" -p "$RCON_PASS" -t web -T 30s "$cmd" 9>&-
}

stop_server_graceful() {
    local countdown="$1"
    local reason="$2"
    if ! is_server_running; then
        log "Server already stopped"
        send_telegram "$(msg already_stopped)" "full"
        return 0
    fi
    log "Sending RCON restart $countdown ($reason)..."
    if rcon_command "restart $countdown $reason"; then
        send_telegram "$(msg rcon_sent)" "full"
    else
        send_telegram "$(msg rcon_error)" "error"
    fi
    log "Waiting for server to stop ($((countdown/60)) min)..."
    sleep "$countdown"
    log "Checking stop status every 10s (up to 3 min)..."
    for ((i=1; i<=18; i++)); do
        if ! is_server_running; then
            log "Server stopped"
            send_telegram "$(msg server_stopped)" "full"
            return 0
        fi
        log "Server still running, attempt $i/18..."
        sleep 10
    done
    log "Force stop via systemd..."
    send_telegram "$(msg force_stop)" "full"
    sudo systemctl stop rustserver
    sleep 30
    return 0
}

start_server() {
    log "Resetting systemd unit state..."
    sudo systemctl stop rustserver 2>/dev/null || true
    sleep 3
    log "Starting server via systemd..."
    sudo systemctl start rustserver
    log "Waiting for process (up to $((SERVER_START_TIMEOUT/60)) min)..."
    local checks=$((SERVER_START_TIMEOUT/10))
    for ((i=1; i<=checks; i++)); do
        sleep 10
        if is_server_running; then
            log "Server started (attempt $i/$checks)"
            return 0
        fi
        log "Waiting for start, attempt $i/$checks..."
    done
    log "ERROR: Server did not start in $((SERVER_START_TIMEOUT/60)) min"
    send_telegram "$(msg start_timeout)" "error"
    return 1
}

check_rust_update_available() {
    local out local_build remote_build
    out=$(lgsm check-update 2>&1)
    local_build=$(grep "Local build:" <<< "$out" | awk '{print $NF}')
    remote_build=$(grep "Remote build:" <<< "$out" | awk '{print $NF}')
    if [ -z "$local_build" ] || [ -z "$remote_build" ]; then
        log "Cannot get versions (Local=$local_build Remote=$remote_build)"
        return 2
    fi
    log "Versions: Local=$local_build Remote=$remote_build"
    if [ "$local_build" != "$remote_build" ]; then
        return 0
    fi
    return 1
}

wait_for_rust_update() {
    local max_wait="$1"
    local interval="$2"
    local elapsed=0
    log "Waiting for Rust update (max $((max_wait/60)) min, check every $((interval/60)) min)..."
    send_telegram "$(msg waiting_update)" "full"
    while [ "$elapsed" -lt "$max_wait" ]; do
        if check_rust_update_available; then
            log "Update detected after $((elapsed/60)) min"
            send_telegram "$(msg update_detected)" "full"
            return 0
        fi
        log "No update yet, waiting $((interval/60)) min (elapsed $((elapsed/60)) min)..."
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    log "TIMEOUT: Rust update did not appear in $((max_wait/60)) min"
    send_telegram "$(msg update_timeout)" "error"
    return 1
}

update_rust() {
    log "Updating Rust..."
    if lgsm update; then
        send_telegram "$(msg rust_updated)" "full"
        return 0
    else
        send_telegram "$(msg rust_update_error)" "error"
        return 1
    fi
}

OXIDE_BACKUP=""

backup_oxide() {
    [[ "$OXIDE_BACKUP_BEFORE_UPDATE" != "true" ]] && return 0
    local managed_dir="$SERVERFILES_DIR/RustDedicated_Data/Managed"
    local backup_dir="$SERVERFILES_DIR/RustDedicated_Data/Managed.backup-$(date +%F)"
    if [ -d "$managed_dir" ]; then
        log "Backup Oxide: $managed_dir -> $backup_dir"
        rm -rf "$backup_dir"
        cp -r "$managed_dir" "$backup_dir" && OXIDE_BACKUP="$backup_dir"
        find "$SERVERFILES_DIR/RustDedicated_Data/" -maxdepth 1 -name "Managed.backup-*" -type d -mtime +30 -exec rm -rf {} \; 2>/dev/null
    fi
}

update_oxide() {
    backup_oxide
    log "Updating Oxide..."
    if lgsm mods-update; then
        send_telegram "$(msg oxide_updated)" "full"
        return 0
    else
        send_telegram "$(msg oxide_update_error)" "error"
        return 1
    fi
}

# Wait until RCON answers. Returns 1 on timeout, 2 if the process died meanwhile.
wait_for_rcon() {
    local waited=0
    log "Waiting for RCON (up to $((OXIDE_LOAD_TIMEOUT/60)) min)..."
    until rcon_command serverinfo >/dev/null 2>&1; do
        is_server_running || { log "Server process died while loading"; return 2; }
        (( waited >= OXIDE_LOAD_TIMEOUT )) && { log "RCON timeout"; return 1; }
        sleep 15
        waited=$((waited + 15))
    done
    log "RCON answers after ~$((waited/60)) min"
    return 0
}

oxide_loaded() {
    rcon_command "oxide.version" 2>/dev/null | grep -q "Oxide"
}

# After a start: make sure the server came up with Oxide; if not, roll Managed/
# back to the copy taken before the Oxide update and start again.
check_oxide_after_start() {
    [[ "$OXIDE_CHECK_ENABLED" != "true" ]] && return 0
    local why rc
    wait_for_rcon; rc=$?
    if [ "$rc" -eq 1 ]; then
        send_telegram "$(msg not_ready)" "error"
        return 1
    elif [ "$rc" -eq 2 ]; then
        why="server crashed while loading"
    elif oxide_loaded; then
        log "Oxide loaded: $(rcon_command oxide.version 2>/dev/null | head -1)"
        return 0
    else
        why="oxide.version did not answer"
    fi
    [[ "$MESSAGES_LANG" == "ru" && "$rc" -eq 2 ]] && why="сервер упал при загрузке"
    [[ "$MESSAGES_LANG" == "ru" && "$rc" -eq 0 ]] && why="oxide.version не отвечает"
    log "Oxide check failed: $why"
    if [ -z "$OXIDE_BACKUP" ] || [ ! -d "$OXIDE_BACKUP" ]; then
        send_telegram "$(msg oxide_no_backup)" "error"
        return 1
    fi
    send_telegram "$(msg oxide_rollback)" "error"
    sudo systemctl stop rustserver
    sleep 5
    local managed_dir="$SERVERFILES_DIR/RustDedicated_Data/Managed"
    rm -rf "$managed_dir" && cp -r "$OXIDE_BACKUP" "$managed_dir"
    if start_server && wait_for_rcon; then
        send_telegram "$(msg oxide_rolled_back)" "error"
        return 0
    fi
    send_telegram "$(msg oxide_rollback_fail)" "error"
    return 1
}

update_system() {
    [[ "$SYSTEM_UPDATE_ENABLED" != "true" ]] && return 0
    log "Updating OS packages (unattended-upgrade)..."
    if sudo /usr/bin/apt-get update -qq && sudo /usr/bin/unattended-upgrade; then
        send_telegram "$(msg os_updated)" "full"
    else
        send_telegram "$(msg os_update_error)" "error"
    fi
}

# Called while the server is down. Returns only if the VM keeps running.
reboot_if_required() {
    # One-time power-off: the host does maintenance (e.g. EFI keys) and starts the VM again
    if [ -f "$SCRIPT_DIR/.poweroff-once" ]; then
        rm -f "$SCRIPT_DIR/.poweroff-once"
        log "Power-off flag found, powering the VM off for host maintenance"
        send_telegram "$(msg poweroff_once)" "full"
        sudo /usr/sbin/poweroff
        exit 0
    fi
    [[ "$REBOOT_IF_REQUIRED" != "true" ]] && return 0
    [ -f /var/run/reboot-required ] || return 0
    log "OS requires a reboot ($(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null)), rebooting instead of starting"
    send_telegram "$(msg rebooting)" "full"
    sudo /usr/sbin/reboot
    exit 0
}

mode_post_boot() {
    log "Boot detected, waiting for the server (up to $((SERVER_START_TIMEOUT/60)) min)..."
    local checks=$((SERVER_START_TIMEOUT/10))
    for ((i=1; i<=checks; i++)); do
        sleep 10
        if is_server_running; then
            log "Server is running after boot (kernel $(uname -r))"
            send_telegram "$(msg booted_ok)" "success"
            return 0
        fi
    done
    send_telegram "$(msg booted_fail)" "error"
    exit 1
}

mode_restart() {
    if [[ "$DAILY_RESTART_ENABLED" != "true" ]]; then
        log "Daily restart disabled in config"
        exit 0
    fi
    if [[ "$SKIP_DAILY_RESTART_ON_FULLWIPE_DAY" == "true" ]] && is_first_thursday; then
        log "Today is Full Wipe day, skipping daily restart"
        send_telegram "$(msg restart_skip)" "full"
        exit 0
    fi
    send_telegram "$(msg restart_started)" "full"
    stop_server_graceful "$DAILY_RESTART_COUNTDOWN" "server_restart"
    [[ "$DAILY_RESTART_UPDATE_RUST" == "true" ]] && update_rust
    [[ "$DAILY_RESTART_UPDATE_OXIDE" == "true" ]] && update_oxide
    update_system
    reboot_if_required
    if start_server; then
        check_oxide_after_start
        send_telegram "$(msg restart_done)" "success"
    else
        exit 1
    fi
}

# kind: full (map + blueprints, waits for the Facepunch update unless forced)
#       map  (map only, never waits for an update)
# force: start now instead of sleeping until the London hour
mode_wipe() {
    local kind="$1"
    local force="${2:-false}"
    local wipe_name wipe_what lgsm_cmd
    if [[ "$kind" == "full" ]]; then
        lgsm_cmd="full-wipe"
        if [[ "$MESSAGES_LANG" == "ru" ]]; then wipe_name="полный вайп"; wipe_what="карта + чертежи"
        else wipe_name="Full Wipe"; wipe_what="map + blueprints"; fi
    else
        lgsm_cmd="map-wipe"
        if [[ "$MESSAGES_LANG" == "ru" ]]; then wipe_name="вайп карты"; wipe_what="только карта, чертежи остаются"
        else wipe_name="Map Wipe"; wipe_what="map only, blueprints kept"; fi
    fi
    if [[ "$kind" == "full" && "$FULLWIPE_ENABLED" != "true" ]]; then
        log "Full Wipe disabled in config (FULLWIPE_ENABLED)"
        exit 0
    fi
    local target_unix
    target_unix=$(TZ=Europe/London date -d "today $FULLWIPE_LONDON_HOUR:00:00" +%s)
    local now_unix=$(date +%s)
    local pre_wait_seconds=$((FULLWIPE_PRE_WAIT_MINUTES * 60))
    local start_at=$((target_unix - pre_wait_seconds))
    local sleep_for=$((start_at - now_unix))
    log "$kind wipe time (London $FULLWIPE_LONDON_HOUR:00) = $(date -d @$target_unix '+%Y-%m-%d %H:%M:%S %Z')"
    if [ "$force" != "true" ] && [ "$sleep_for" -gt 0 ]; then
        log "Sleeping $((sleep_for/60)) min until preparation start..."
        send_telegram "$(msg wipe_today)" "full"
        sleep "$sleep_for"
    else
        log "Time already passed or force mode, starting immediately"
    fi
    send_telegram "$(msg wipe_prep)" "full"
    stop_server_graceful "$FULLWIPE_COUNTDOWN" "WIPE"
    # Only the scheduled full wipe waits for Facepunch; manual and map wipes update if one is out
    if [[ "$kind" == "full" && "$force" != "true" ]]; then
        if ! wait_for_rust_update "$FULLWIPE_UPDATE_WAIT_MAX" "$FULLWIPE_UPDATE_CHECK_INTERVAL"; then
            log "Update wait timeout, aborting wipe"
            exit 1
        fi
    else
        log "Not waiting for a Facepunch update"
    fi
    if ! update_rust; then
        send_telegram "$(msg wipe_abort_update)" "error"
        exit 1
    fi
    update_oxide
    log "Performing $kind wipe (LGSM $lgsm_cmd)..."
    send_telegram "$(msg wipe_running)" "full"
    if lgsm "$lgsm_cmd"; then
        send_telegram "$(msg wipe_done)" "full"
    else
        send_telegram "$(msg wipe_error)" "error"
        exit 1
    fi
    local open_spec open_unix="" open_at round=0
    if [[ "$kind" == "full" ]]; then open_spec="$FULLWIPE_OPEN_TIME"; else open_spec="$MAPWIPE_OPEN_TIME"; fi
    if [[ "$open_spec" =~ ^\+([0-9]+)$ ]]; then
        # "+5": open at the next 5-minute mark after the server is up; the hour ahead is
        # only the safety-net time for tick until the real one is known
        round=${BASH_REMATCH[1]}
        open_unix=$(( $(date +%s) + 3600 ))
    else
        open_unix=$(open_time_today "$open_spec")
    fi
    [ -n "$open_unix" ] && { gate_close "$open_unix" || open_unix=""; }
    if start_server; then
        check_oxide_after_start
        send_telegram "$(msg wipe_live)" "success"
    else
        exit 1
    fi
    if [ -n "$open_unix" ]; then
        wait_for_rcon >/dev/null
        if (( round > 0 )); then
            open_unix=$(( ($(date +%s) / (round * 60) + 1) * round * 60 ))
            echo "$open_unix $(cut -d' ' -f2 "$GATE_FILE")" > "$GATE_FILE"
        fi
        open_at=$(date -d @"$open_unix" +%H:%M)
        send_telegram "$(msg gate_closed)" "full"
        local wait_s=$(( open_unix - $(date +%s) ))
        (( wait_s > 0 )) && sleep "$wait_s"
        gate_open
    fi
    rm -f "$STATE_DIR/wipetimer"
}

# Legacy Thursday cron entry (before "tick"): Full Wipe on the first Thursday only
mode_legacy_fullwipe() {
    if is_first_thursday; then
        mode_wipe full false
    else
        log "Not first Thursday, exit"
        exit 0
    fi
}

# An event is due once per day, inside [start, start + window) - a VM that was
# off at the scheduled time does not run it hours late.
due() {
    local name="$1" start="$2" window_min="$3"
    local now stamp
    now=$(date +%s)
    stamp="$STATE_DIR/done-$name-$(date +%F)"
    (( now >= start && now < start + window_min * 60 )) || return 1
    [ -f "$stamp" ] && return 1
    touch "$stamp"
    return 0
}

# MAPWIPE_MONTH_DAYS="16-22": map wipes only on those days of the month; empty = any day
in_mapwipe_month_days() {
    [ -z "$MAPWIPE_MONTH_DAYS" ] && return 0
    local dom from to
    dom=$(date +%-d)
    from=${MAPWIPE_MONTH_DAYS%-*}
    to=${MAPWIPE_MONTH_DAYS#*-}
    (( dom >= from && dom <= to ))
}

days_since_map_wipe() {
    local newest
    newest=$(find "$SERVERFILES_DIR/server/$LGSM_SELFNAME" -maxdepth 1 -name '*.map' -printf '%T@\n' 2>/dev/null | sort -n | tail -1)
    [ -z "$newest" ] && { echo 9999; return; }
    echo $(( ($(date +%s) - ${newest%.*}) / 86400 ))
}

# ---- Opening gate: after a wipe the server comes up with maxplayers 0, so everyone who
# connects waits in Rust's own queue, and at *_OPEN_TIME maxplayers goes back and the
# queue joins in arrival order. The real value lives in LGSM's config; the gate file keeps
# "open_unix maxplayers" so the next tick reopens even if this run dies.
LGSM_CFG="$(dirname "$LGSM_SCRIPT")/lgsm/config-lgsm/$LGSM_SELFNAME/$LGSM_SELFNAME.cfg"
GATE_FILE="$STATE_DIR/gate"

gate_close() {
    local open_unix="$1" max
    max=$(sed -n 's/^maxplayers="\([0-9]*\)".*/\1/p' "$LGSM_CFG")
    [ -z "$max" ] || [ "$max" -eq 0 ] && { log "Gate: no maxplayers in $LGSM_CFG, not closing"; return 1; }
    echo "$open_unix $max" > "$GATE_FILE"
    sed -i 's/^maxplayers="[0-9]*"/maxplayers="0"/' "$LGSM_CFG"
    log "Gate closed until $(date -d @"$open_unix" '+%F %T') (maxplayers $max -> 0)"
}

gate_open() {
    [ -f "$GATE_FILE" ] || return 0
    local open_unix max
    read -r open_unix max < "$GATE_FILE"
    sed -i "s/^maxplayers=\"[0-9]*\"/maxplayers=\"$max\"/" "$LGSM_CFG"
    if is_server_running && ! rcon_command "server.maxplayers $max" >/dev/null 2>&1; then
        log "Gate: RCON did not answer, will retry"
        return 1
    fi
    rm -f "$GATE_FILE"
    log "Gate opened (maxplayers $max)"
    send_telegram "$(msg gate_opened)" "success"
}

# The wipe run itself waits for the opening time; tick is the safety net
gate_check() {
    [ -f "$GATE_FILE" ] || return 0
    local open_unix max
    read -r open_unix max < "$GATE_FILE"
    (( $(date +%s) >= open_unix )) && gate_open
    return 0
}

# Unix time of HH:MM today, or empty when the setting is empty or that time has passed
open_time_today() {
    [ -z "$1" ] && return 0
    local t
    t=$(date -d "today $1" +%s) || return 0
    (( t > $(date +%s) )) && echo "$t"
}

# ---- Wipe timer: Rust shows "next wipe in ..." in the server browser. Feed it the real
# next wipe from this schedule through wipetimer.wipeunixtimestampoverride.
next_wipe_unix() {
    local best="" d ts day dow
    for ((d=0; d<=62; d++)); do
        day=$(date -d "today +$d day" +%F)
        dow=$(date -d "$day" +%u)
        ts=""
        if [[ "$FULLWIPE_ENABLED" == "true" && "$dow" == "4" ]] && (( 10#$(date -d "$day" +%d) <= 7 )); then
            ts=$(TZ=Europe/London date -d "$day $FULLWIPE_LONDON_HOUR:00:00" +%s)
        elif [[ "$MAPWIPE_ENABLED" == "true" && "$dow" == "$MAPWIPE_DAY" ]]; then
            local dom from to
            dom=$(date -d "$day" +%-d)
            from=${MAPWIPE_MONTH_DAYS%-*}; to=${MAPWIPE_MONTH_DAYS#*-}
            if [ -z "$MAPWIPE_MONTH_DAYS" ] || (( dom >= from && dom <= to )); then
                if [ -n "$MAPWIPE_OPEN_TIME" ]; then
                    ts=$(date -d "$day $MAPWIPE_OPEN_TIME" +%s)
                else
                    ts=$(( $(date -d "$day $MAPWIPE_TIME" +%s) + FULLWIPE_COUNTDOWN ))
                fi
            fi
        fi
        if [ -n "$ts" ] && (( ts > $(date +%s) )); then best=$ts; break; fi
    done
    echo "$best"
}

wipetimer_check() {
    [[ "$WIPETIMER_ENABLED" != "true" ]] && return 0
    is_server_running || return 0
    local next pid stamp
    next=$(next_wipe_unix)
    [ -z "$next" ] && return 0
    pid=$(pgrep -x RustDedicated | head -1)
    # leave a loading server alone (RCON is not up yet, every try would wait 30 s)
    (( $(ps -o etimes= -p "$pid" | tr -d ' ') < 900 )) && return 0
    stamp="$next $pid"
    [[ "$(cat "$STATE_DIR/wipetimer" 2>/dev/null)" == "$stamp" ]] && return 0
    rcon_command "wipetimer.wipeunixtimestampoverride $next" >/dev/null 2>&1 || return 0
    echo "$stamp" > "$STATE_DIR/wipetimer"
    log "Wipe timer set: next wipe $(date -d @"$next" '+%F %T %Z')"
}

# Every minute from cron: runs whatever config.env schedules for now, else the watchdog
mode_tick() {
    find "$STATE_DIR" -maxdepth 1 -name 'done-*' -mtime +7 -delete 2>/dev/null
    gate_check
    local full_day=false
    [[ "$FULLWIPE_ENABLED" == "true" ]] && is_first_thursday && full_day=true

    # Full Wipe: first Thursday, from (London hour - pre-wait), 3 h window
    if $full_day; then
        local fw_start
        fw_start=$(( $(TZ=Europe/London date -d "today $FULLWIPE_LONDON_HOUR:00:00" +%s) - FULLWIPE_PRE_WAIT_MINUTES * 60 ))
        if due fullwipe "$fw_start" 180; then
            cleanup_logs
            mode_wipe full false
            exit 0
        fi
    fi

    # Map Wipe: MAPWIPE_DAY at MAPWIPE_TIME, every MAPWIPE_INTERVAL_WEEKS counted from the last wipe,
    # only inside MAPWIPE_MONTH_DAYS when that is set
    if [[ "$MAPWIPE_ENABLED" == "true" && "$(date +%u)" == "$MAPWIPE_DAY" ]] && ! $full_day && in_mapwipe_month_days; then
        if due mapwipe "$(date -d "today $MAPWIPE_TIME" +%s)" 60; then
            local days
            days=$(days_since_map_wipe)
            if (( days >= MAPWIPE_INTERVAL_WEEKS * 7 - 1 )); then
                cleanup_logs
                mode_wipe map true
                exit 0
            fi
            log "Map wipe day, but the last wipe was $days days ago (every $MAPWIPE_INTERVAL_WEEKS wk), skipping"
        fi
    fi

    if [[ "$DAILY_RESTART_ENABLED" == "true" ]] && due restart "$(date -d "today $DAILY_RESTART_TIME" +%s)" 60; then
        cleanup_logs
        mode_restart
        exit 0
    fi

    wipetimer_check
    mode_watchdog
}

# From tick (every minute) or its own cron entry. Restarts a crashed or hung server, never one
# that was stopped on purpose (LGSM removes its started.lock on a clean stop).
mode_watchdog() {
    [[ "$WATCHDOG_ENABLED" != "true" ]] && exit 0
    local uptime_s
    uptime_s=$(cut -d. -f1 /proc/uptime)
    (( uptime_s < 600 )) && exit 0                     # fresh boot: post-boot handles it
    [ -f "$LGSM_LOCK_DIR/$LGSM_SELFNAME-started.lock" ] || { rm -f "$STATE_DIR/hang"; exit 0; }
    [ -f "$LGSM_LOCK_DIR/$LGSM_SELFNAME-starting.lock" ] && exit 0
    local why=""
    if ! is_server_running; then
        why="crashed"
    else
        local age
        age=$(ps -o etimes= -C RustDedicated | sort -n | tail -1 | tr -d ' ')
        if (( ${age:-0} < WATCHDOG_GRACE )) || rcon_command serverinfo >/dev/null 2>&1; then
            rm -f "$STATE_DIR/hang" "$STATE_DIR/gave_up"
            exit 0
        fi
        local n=$(( $(cat "$STATE_DIR/hang" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$STATE_DIR/hang"
        log "Watchdog: RCON not answering ($n/$WATCHDOG_HANG_CHECKS)"
        (( n < WATCHDOG_HANG_CHECKS )) && exit 0
        rm -f "$STATE_DIR/hang"
        why="hung"
    fi
    local now recent
    now=$(date +%s)
    recent=$(awk -v t=$((now - 3600)) '$1 > t' "$STATE_DIR/restarts" 2>/dev/null | wc -l)
    if (( recent >= WATCHDOG_MAX_RESTARTS )); then
        if [ ! -f "$STATE_DIR/gave_up" ]; then
            touch "$STATE_DIR/gave_up"
            log "Watchdog: $recent restarts within an hour, giving up"
            send_telegram "$(msg wd_give_up)" "error"
        fi
        exit 0
    fi
    { awk -v t=$((now - 3600)) '$1 > t' "$STATE_DIR/restarts" 2>/dev/null; echo "$now"; } > "$STATE_DIR/restarts.new"
    mv -f "$STATE_DIR/restarts.new" "$STATE_DIR/restarts"
    log "Watchdog: server $why, restarting"
    if [[ "$why" == "hung" ]]; then
        send_telegram "$(msg wd_hung)" "error"
    else
        send_telegram "$(msg wd_crashed)" "error"
    fi
    if start_server; then
        send_telegram "$(msg wd_restarted)" "success"
    else
        send_telegram "$(msg wd_restart_fail)" "error"
    fi
}

MODE="${1:-}"
case "$MODE" in
    restart)
        acquire_lock; cleanup_logs
        mode_restart
        ;;
    tick)
        acquire_lock quiet
        mode_tick
        ;;
    fullwipe)
        acquire_lock; cleanup_logs
        mode_legacy_fullwipe
        ;;
    fullwipe-now)
        acquire_lock; cleanup_logs
        log "Manual Full Wipe (no date check)"
        mode_wipe full true
        ;;
    mapwipe-now)
        acquire_lock; cleanup_logs
        log "Manual Map Wipe (no date check)"
        mode_wipe map true
        ;;
    post-boot)
        acquire_lock; cleanup_logs
        mode_post_boot
        ;;
    watchdog)
        acquire_lock quiet
        mode_watchdog
        ;;
    test-telegram)
        send_telegram "$(msg test)" "full"
        ;;
    check-update)
        if check_rust_update_available; then
            echo "UPDATE AVAILABLE"
            exit 0
        else
            echo "No update"
            exit 1
        fi
        ;;
    *)
        echo "Usage: $0 {tick|restart|fullwipe|fullwipe-now|mapwipe-now|post-boot|watchdog|test-telegram|check-update}"
        echo ""
        echo "  tick           - cron every minute: runs the schedule from config.env + watchdog"
        echo "  restart        - daily restart now (auto-skips on Full Wipe day)"
        echo "  fullwipe       - legacy cron entry: Full Wipe only on the first Thursday"
        echo "  fullwipe-now   - Full Wipe immediately, no date check, no update wait"
        echo "  mapwipe-now    - Map Wipe immediately (blueprints kept)"
        echo "  post-boot      - report the server state after a VM boot (@reboot cron)"
        echo "  watchdog       - restart a crashed or hung server (cron every few minutes)"
        echo "  test-telegram  - test Telegram notifications"
        echo "  check-update   - check Rust update availability"
        exit 1
        ;;
esac
