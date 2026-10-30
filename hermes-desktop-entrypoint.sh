#!/usr/bin/env bash
set -Eeuo pipefail

# Use TunMax's current desktop implementation with our existing Hermes services.
# The upstream OpenClaw config normalizer and gateway are intentionally unused.
source /bz/lib/common.sh
source /bz/lib/desktop.sh

export LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8 LANGUAGE=zh_CN:zh
export HOME="${HOME:-/root}" USER="${USER:-root}" DISPLAY="$BZ_DISPLAY"
export PATH="/root/.local/bin:/usr/local/nodejs/bin:/usr/local/node/bin:$PATH"
export OPENCLAW_DISABLE_BONJOUR="${OPENCLAW_DISABLE_BONJOUR:-1}"
dashboard_pid=""
shutdown_hermes() {
    trap - TERM INT
    log_info "Stopping managed Hermes services"
    for pid in "${BZ_GATEWAY_PID:-}" "$dashboard_pid" "${BZ_SYNC_DAEMON_PID:-}"; do
        [[ -z "$pid" ]] || kill -TERM "$pid" 2>/dev/null || true
    done
    for pid in "${BZ_GATEWAY_PID:-}" "$dashboard_pid"; do
        [[ -z "$pid" ]] || wait "$pid" 2>/dev/null || true
    done
    stop_bg_processes
    vncserver -kill "$BZ_DISPLAY" >/dev/null 2>&1 || true
    exit 0
}
trap shutdown_hermes TERM INT
chmod 1777 /tmp
require_cmd vncserver websockify rclone curl jq
desktop_kill_stale_vnc
desktop_start_vnc
desktop_wait_vnc || log_warn "Desktop is still starting"
desktop_load_dbus_env || true
desktop_export_env
desktop_start_novnc
printf 'root:%s\n' "${ROOT_PASSWD:-123456}" | chpasswd

if [[ "${SKIP_RESTORE:-0}" != 1 ]]; then
    mkdir -p /mnt/workspace/root
    if [[ -d /mnt/workspace/root ]]; then
    log_info "Restoring Hermes user files with cache and active-database exclusions"
    rclone copy /mnt/workspace/root/ /root/ \
        --filter-from /bz/rules.txt --create-empty-src-dirs --links \
        --metadata --transfers 4 --checkers 8 \
        --stats 60s --stats-log-level NOTICE
    fi
    mkdir -p /root/.hermes/logs
    chmod 0700 /root/.hermes
    for profile_home in /root/.hermes /root/.hermes/profiles/*; do
        [[ -d "$profile_home" ]] || continue
        for private_file in .env auth.json config.yaml; do
            [[ ! -f "$profile_home/$private_file" ]] || chmod 0600 "$profile_home/$private_file"
        done
    done
    for private_dir in credentials secrets; do
        if [[ -d "/root/.hermes/$private_dir" ]]; then
            chmod 0700 "/root/.hermes/$private_dir"
            find "/root/.hermes/$private_dir" -type f -exec chmod 0600 {} +
        fi
    done
    if [[ -s /root/bz-startup/main.sh ]]; then
        chmod 0700 /root/bz-startup/main.sh
        log_info "Restoring deployment databases and pinned Hermes runtime"
        /bin/bash /root/bz-startup/main.sh || die "Hermes persistent recovery hook failed"
    else
        if [[ -s /mnt/workspace/hermes-persistent/database-snapshots/latest.json ]]; then
            HERMES_BOOT_RESTORE=1 /usr/bin/python3 /opt/hermes-image/sqlite_checkpoint.py restore
        fi
        nohup /root/.hermes/hermes-agent/venv/bin/python /opt/hermes-image/sqlite_checkpoint.py daemon >>/root/.hermes/logs/database-checkpoint.log 2>&1 &
    fi
    nohup /bz/sync_daemon.sh >>/root/.hermes/logs/platform-sync.log 2>&1 &
    BZ_SYNC_DAEMON_PID=$!
fi

mkdir -p /root/.hermes/logs
nohup /root/.local/bin/hermes dashboard >>/root/.hermes/logs/dashboard-supervisor.log 2>&1 &
dashboard_pid=$!
nohup /root/.local/bin/hermes gateway run --accept-hooks >>/root/.hermes/logs/gateway-supervisor.log 2>&1 &
BZ_GATEWAY_PID=$!
if wait_for_http http://127.0.0.1:9119/ 120 "Hermes dashboard"; then
    google-chrome-stable --no-sandbox --disable-dev-shm-usage --disable-gpu \
        --disable-software-rasterizer --test-type http://127.0.0.1:9119/ >/dev/null 2>&1 &
else
    log_warn "Hermes dashboard is still starting; managed services continue running"
fi
log_info "TunMax desktop and Hermes initialization complete"
wait_forever
