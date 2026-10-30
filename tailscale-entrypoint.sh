#!/bin/sh
set -u
TAILSCALE_STATE_DIR=/mnt/workspace/tailscale
TAILSCALE_SOCKET=/tmp/tailscaled.sock
TAILSCALE_HOSTNAME=${TAILSCALE_HOSTNAME:-hermes-computer}
HERMES_EXPECTED_VERSION=0.22.5
HERMES_EXPECTED_COMMIT=bf0203a794a07aac3ff764972ab9087baa4e4f4e
SKIP_RESTORE=${SKIP_RESTORE:-0}
export SKIP_RESTORE
verify_image_hermes_runtime() {
  hermes_runtime=/root/.hermes/hermes-agent
  hermes_cli="$hermes_runtime/venv/bin/hermes"

  if [ ! -x "$hermes_cli" ]; then
    echo "[HERMES_RUNTIME] ERROR missing executable: $hermes_cli"
    return 1
  fi

  actual_version=$(
    PYTHONPATH="$hermes_runtime" "$hermes_runtime/venv/bin/python" -c \
      'from hermes_cli.version_info import get_code_identity; print(get_code_identity()["version"])' \
      2>/dev/null
  ) || actual_version=unknown
  actual_commit=$(git -C "$hermes_runtime" rev-parse HEAD 2>/dev/null) || actual_commit=unknown

  if [ "$actual_version" != "$HERMES_EXPECTED_VERSION" ]; then
    echo "[HERMES_RUNTIME] ERROR version=$actual_version expected=$HERMES_EXPECTED_VERSION"
    return 1
  fi
  if [ "$actual_commit" != "$HERMES_EXPECTED_COMMIT" ]; then
    echo "[HERMES_RUNTIME] ERROR commit=$actual_commit expected=$HERMES_EXPECTED_COMMIT"
    return 1
  fi

  echo "[HERMES_RUNTIME] READY version=$actual_version commit=$actual_commit persistence=/mnt/workspace"
}


verify_image_hermes_runtime || exit 1
if [ "${HERMES_VERIFY_ONLY:-0}" = 1 ]; then
  exit 0
fi
# Load persistence filters before the base image copies any user state.
# Active SQLite is restored from Online Backup API checkpoints by main.sh.
if [ "$SKIP_RESTORE" != 1 ] && [ -s /mnt/workspace/hermes-persistent/bootstrap/runtime-sync-rules.txt ]; then
  cp /mnt/workspace/hermes-persistent/bootstrap/runtime-sync-rules.txt /bz/rules.txt || exit 1
  cp /mnt/workspace/hermes-persistent/bootstrap/platform-sync-daemon.sh /bz/sync_daemon.sh || exit 1
  chmod 0700 /bz/sync_daemon.sh
fi
# Persisted model settings are user-owned; startup must never rewrite them.
if [ -z "${TAILSCALE_AUTHKEY:-}" ] && [ ! -s "$TAILSCALE_STATE_DIR/tailscaled.state" ]; then
  exec /entrypoint.sh
fi
mkdir -p "$TAILSCALE_STATE_DIR"

echo "[TAILSCALE] starting userspace daemon hostname=$TAILSCALE_HOSTNAME"
tailscaled \
  --tun=userspace-networking \
  --state="$TAILSCALE_STATE_DIR/tailscaled.state" \
  --socket="$TAILSCALE_SOCKET" \
  >"$TAILSCALE_STATE_DIR/tailscaled.log" 2>&1 &

daemon_ready=no
for attempt in $(seq 1 30)
do
  if [ -S "$TAILSCALE_SOCKET" ]; then
    daemon_ready=yes
    break
  fi
  sleep 1
done

if [ "$daemon_ready" = yes ]; then
  if tailscale --socket="$TAILSCALE_SOCKET" status --json 2>/dev/null | grep -q '"BackendState"[[:space:]]*:[[:space:]]*"Running"'; then
    echo "[TAILSCALE] reused persisted node state"
  elif [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
    tailscale_up_log=/tmp/tailscale-up.log
    if tailscale --socket="$TAILSCALE_SOCKET" up \
      --auth-key="$TAILSCALE_AUTHKEY" \
      --hostname="$TAILSCALE_HOSTNAME" \
      --ssh=false \
      --accept-dns=false \
      >"$tailscale_up_log" 2>&1; then
      echo "[TAILSCALE] authentication succeeded"
    else
      echo "[TAILSCALE] authentication failed; Hermes will still start"
    fi
    rm -f "$tailscale_up_log"
  else
    echo "[TAILSCALE] no auth key and no persisted login; Hermes will still start"
  fi

  # Keep Tailscale as the private network only. The persisted startup hook
  # starts ordinary OpenSSH with root password authentication; enabling
  # Tailscale SSH here would intercept port 22 with a browser approval check.
  tailscale --socket="$TAILSCALE_SOCKET" set --ssh=false >/dev/null 2>&1 || true

  tailscale_ip=$(tailscale --socket="$TAILSCALE_SOCKET" ip -4 2>/dev/null | head -n 1)
  if [ -n "$tailscale_ip" ]; then
    echo "[TAILSCALE] READY ip=$tailscale_ip hostname=$TAILSCALE_HOSTNAME tailscale_ssh=disabled"
  else
    echo "[TAILSCALE] not connected"
  fi
else
  echo "[TAILSCALE] daemon did not become ready; Hermes will still start"
fi

echo "[HERMES_STARTUP] handoff entrypoint skip_restore=$SKIP_RESTORE"
if [ ! -x /entrypoint.sh ]; then
  echo "[HERMES_STARTUP] ERROR entrypoint_not_executable" >&2
  exit 126
fi
exec /entrypoint.sh
