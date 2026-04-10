#!/bin/bash
# ============================================================================
# Rust Wipe Manager
# https://github.com/wobujidao/rust-wipe-manager
# ============================================================================

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
SECRETS_FILE="$SCRIPT_DIR/.secrets.env"

[ -f "$CONFIG_FILE" ] || { echo "ERROR: $CONFIG_FILE not found"; exit 1; }
[ -f "$SECRETS_FILE" ] || { echo "ERROR: $SECRETS_FILE not found"; exit 1; }
source "$CONFIG_FILE"
source "$SECRETS_FILE"

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/manager-$(date +%Y%m%d).log"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

check_telegram_api() {
    local response
    response=$(curl -s --connect-timeout 5 "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getMe" 2>&1)
    if [[ $? -ne 0 || "$response" =~ "error_code" || ! "$response" =~ "\"ok\":true" ]]; then
        log "Telegram API error: $response"
        return 1
    fi
    return 0
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
    check_telegram_api || return 1
    local response
    response=$(curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" -d chat_id="$TELEGRAM_CHAT_ID" -d text="$message" -d parse_mode="Markdown" 2>&1)
    if [[ $? -ne 0 || "$response" =~ "error_code" ]]; then
        log "Telegram send error: $response"
        return 1
    fi
    return 0
}

is_server_running() {
    ps aux | grep -v grep | grep -q "RustDedicated"
}

is_first_thursday() {
    local day=$(date +%d)
    local dow=$(date +%u)
    [[ "$dow" == "4" && "$day" -ge 1 && "$day" -le 7 ]]
}

rcon_command() {
    local cmd="$1"
    if [ ! -x "$RCON_CLI" ]; then
        log "ERROR: rcon-cli not found: $RCON_CLI"
        return 1
    fi
    "$RCON_CLI" -a "$RCON_HOST:$RCON_PORT" -p "$RCON_PASS" -t web -T 30s "$cmd"
}

stop_server_graceful() {
    local countdown="$1"
    local reason="$2"
    if ! is_server_running; then
        log "Server already stopped"
        send_telegram "ℹ️ $SERVER_TAG: Server already stopped" "full"
        return 0
    fi
    log "Sending RCON restart $countdown ($reason)..."
    if rcon_command "restart $countdown $reason"; then
        send_telegram "📡 $SERVER_TAG: RCON sent (countdown $((countdown/60)) min, reason: $reason)" "full"
    else
        send_telegram "❌ $SERVER_TAG: RCON send error" "error"
    fi
    log "Waiting for server to stop ($((countdown/60)) min)..."
    sleep "$countdown"
    log "Checking stop status every 10s (up to 3 min)..."
    for ((i=1; i<=18; i++)); do
        if ! is_server_running; then
            log "Server stopped"
            send_telegram "🛑 $SERVER_TAG: Server stopped" "full"
            return 0
        fi
        log "Server still running, attempt $i/18..."
        sleep 10
    done
    log "Force stop via systemd..."
    send_telegram "⚠️ $SERVER_TAG: Force stop" "full"
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
    send_telegram "❌ $SERVER_TAG: Server did not start in $((SERVER_START_TIMEOUT/60)) min" "error"
    return 1
}

check_rust_update_available() {
    local local_build remote_build
    local_build=$("$LGSM_SCRIPT" check-update 2>&1 | grep "Local build:" | awk '{print $NF}')
    remote_build=$("$LGSM_SCRIPT" check-update 2>&1 | grep "Remote build:" | awk '{print $NF}')
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
    send_telegram "⏳ $SERVER_TAG: Waiting for Rust update from Facepunch..." "full"
    while [ "$elapsed" -lt "$max_wait" ]; do
        if check_rust_update_available; then
            log "Update detected after $((elapsed/60)) min"
            send_telegram "🎉 $SERVER_TAG: Rust update detected after $((elapsed/60)) min wait" "full"
            return 0
        fi
        log "No update yet, waiting $((interval/60)) min (elapsed $((elapsed/60)) min)..."
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    log "TIMEOUT: Rust update did not appear in $((max_wait/60)) min"
    send_telegram "🚨 $SERVER_TAG: TIMEOUT! Rust update did not appear in $((max_wait/60)) min. Manual intervention required!" "error"
    return 1
}

update_rust() {
    log "Updating Rust..."
    if "$LGSM_SCRIPT" update; then
        send_telegram "✅ $SERVER_TAG: Rust updated" "full"
        return 0
    else
        send_telegram "❌ $SERVER_TAG: Rust update error" "error"
        return 1
    fi
}

backup_oxide() {
    [[ "$OXIDE_BACKUP_BEFORE_UPDATE" != "true" ]] && return 0
    local managed_dir="$SERVERFILES_DIR/RustDedicated_Data/Managed"
    local backup_dir="$SERVERFILES_DIR/RustDedicated_Data/Managed.backup-$(date +%F)"
    if [ -d "$managed_dir" ]; then
        log "Backup Oxide: $managed_dir -> $backup_dir"
        rm -rf "$backup_dir"
        cp -r "$managed_dir" "$backup_dir"
        find "$SERVERFILES_DIR/RustDedicated_Data/" -maxdepth 1 -name "Managed.backup-*" -type d -mtime +30 -exec rm -rf {} \; 2>/dev/null
    fi
}

update_oxide() {
    backup_oxide
    log "Updating Oxide..."
    if "$LGSM_SCRIPT" mods-update; then
        send_telegram "✅ $SERVER_TAG: Oxide updated" "full"
        return 0
    else
        send_telegram "❌ $SERVER_TAG: Oxide update error" "error"
        return 1
    fi
}

mode_restart() {
    if [[ "$DAILY_RESTART_ENABLED" != "true" ]]; then
        log "Daily restart disabled in config"
        exit 0
    fi
    if [[ "$SKIP_DAILY_RESTART_ON_FULLWIPE_DAY" == "true" ]] && is_first_thursday; then
        log "Today is Full Wipe day, skipping daily restart"
        send_telegram "ℹ️ $SERVER_TAG: Skipping daily restart — today is Full Wipe day" "full"
        exit 0
    fi
    send_telegram "🛠 $SERVER_NAME: Daily restart started (countdown $((DAILY_RESTART_COUNTDOWN/60)) min)" "full"
    stop_server_graceful "$DAILY_RESTART_COUNTDOWN" "server_restart"
    [[ "$DAILY_RESTART_UPDATE_RUST" == "true" ]] && update_rust
    [[ "$DAILY_RESTART_UPDATE_OXIDE" == "true" ]] && update_oxide
    if start_server; then
        send_telegram "✅ $SERVER_TAG: Daily restart completed successfully" "success"
    else
        exit 1
    fi
}

mode_fullwipe() {
    local force="${1:-false}"
    if [[ "$FULLWIPE_ENABLED" != "true" ]]; then
        log "Full Wipe disabled in config"
        exit 0
    fi
    if [[ "$force" != "true" ]]; then
        if ! is_first_thursday; then
            log "Not first Thursday, exit"
            exit 0
        fi
    fi
    local target_unix
    target_unix=$(TZ=Europe/London date -d "today $FULLWIPE_LONDON_HOUR:00:00" +%s)
    local now_unix=$(date +%s)
    local pre_wait_seconds=$((FULLWIPE_PRE_WAIT_MINUTES * 60))
    local start_at=$((target_unix - pre_wait_seconds))
    local sleep_for=$((start_at - now_unix))
    log "Full Wipe time (London $FULLWIPE_LONDON_HOUR:00) = $(date -d @$target_unix '+%Y-%m-%d %H:%M:%S %Z')"
    log "Will start preparation at = $(date -d @$start_at '+%Y-%m-%d %H:%M:%S %Z')"
    if [ "$force" != "true" ] && [ "$sleep_for" -gt 0 ]; then
        log "Sleeping $((sleep_for/60)) min until preparation start..."
        send_telegram "🕐 $SERVER_TAG: Full Wipe today. Preparation in $((sleep_for/60)) min" "full"
        sleep "$sleep_for"
    else
        log "Time already passed or force mode, starting immediately"
    fi
    send_telegram "🔥 $SERVER_NAME: FULL WIPE PREPARATION STARTED" "full"
    stop_server_graceful "$FULLWIPE_COUNTDOWN" "FULL_WIPE_UPDATE"
    if ! wait_for_rust_update "$FULLWIPE_UPDATE_WAIT_MAX" "$FULLWIPE_UPDATE_CHECK_INTERVAL"; then
        log "Update wait timeout, aborting Full Wipe"
        exit 1
    fi
    if ! update_rust; then
        send_telegram "🚨 $SERVER_TAG: Rust update failed, aborting Full Wipe" "error"
        exit 1
    fi
    update_oxide
    log "Performing Full Wipe (LGSM full-wipe)..."
    send_telegram "🗑 $SERVER_TAG: Performing Full Wipe (map + blueprints)" "full"
    if "$LGSM_SCRIPT" full-wipe; then
        send_telegram "✅ $SERVER_TAG: Full Wipe completed" "full"
    else
        send_telegram "❌ $SERVER_TAG: Full Wipe error" "error"
        exit 1
    fi
    if start_server; then
        send_telegram "🎉 $SERVER_NAME: NEW WIPE IS LIVE! Server updated and ready" "success"
    else
        exit 1
    fi
}

case "${1:-}" in
    restart)
        mode_restart
        ;;
    fullwipe)
        mode_fullwipe false
        ;;
    fullwipe-now)
        log "Manual Full Wipe (no date check)"
        mode_fullwipe true
        ;;
    test-telegram)
        send_telegram "🧪 $SERVER_TAG: Telegram notification test" "full"
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
        echo "Usage: $0 {restart|fullwipe|fullwipe-now|test-telegram|check-update}"
        echo ""
        echo "  restart        - daily restart (auto-skips on Full Wipe day)"
        echo "  fullwipe       - Full Wipe (only on first Thursday of month)"
        echo "  fullwipe-now   - Full Wipe immediately, no date check (manual/test)"
        echo "  test-telegram  - test Telegram notifications"
        echo "  check-update   - check Rust update availability"
        exit 1
        ;;
esac
