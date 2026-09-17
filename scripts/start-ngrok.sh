#!/usr/bin/env bash
# =============================================================================
# scripts/start-ngrok.sh
#
# Starts the ngrok secure tunnels:
#   - rdp : TCP tunnel to 127.0.0.1:3389 (Windows Remote Desktop)
#   - api : HTTPS tunnel to the local status/management API (token protected)
#
# The authtoken is never hard-coded. It is read from NGROK_AUTHTOKEN and
# written only to a mode-0600 config file under the ephemeral /run tmpfs.
#
# Only the tunnels listed in NGROK_TUNNELS are exposed. Nothing else is.
# =============================================================================
set -Eeuo pipefail

VM_STATE_DIR="${VM_STATE_DIR:-/run/windows-vm}"
VM_LOG_DIR="${VM_LOG_DIR:-/var/log/windows-vm}"
NGROK_ENABLED="${NGROK_ENABLED:-false}"
NGROK_REQUIRED="${NGROK_REQUIRED:-false}"
NGROK_AUTHTOKEN="${NGROK_AUTHTOKEN:-}"
NGROK_TUNNELS="${NGROK_TUNNELS:-rdp}"
NGROK_RDP_ADDR="${NGROK_RDP_ADDR:-3389}"
NGROK_API_ADDR="${NGROK_API_ADDR:-10000}"
NGROK_START_TIMEOUT="${NGROK_START_TIMEOUT:-45}"

NGROK_CONFIG="${VM_STATE_DIR}/ngrok.yml"
NGROK_PID_FILE="${VM_STATE_DIR}/ngrok.pid"
NGROK_LOG="${VM_LOG_DIR}/ngrok.log"
NGROK_URLS="${VM_STATE_DIR}/ngrok-urls.json"

log()  { printf '[NGROK] %s\n' "$*"; }
warn() { printf '[NGROK][WARN] %s\n' "$*" >&2; }
err()  { printf '[NGROK][ERROR] %s\n' "$*" >&2; }

is_true() {
    case "${1,,}" in
        true|1|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

# ngrok may echo the authtoken in its error messages (for example when the
# token is invalid). Never print raw ngrok output to the container logs
# without redacting the secret first.
redact_secrets() {
    local token="${NGROK_AUTHTOKEN:-}"
    if [[ -z "$token" ]]; then
        cat
        return 0
    fi
    local escaped="${token//\\/\\\\}"
    escaped="${escaped//&/\\&}"
    escaped="${escaped//|/\\|}"
    sed "s|${escaped}|***REDACTED***|g"
}

# Remove the authtoken from the on-disk ngrok log after a failure. The log is
# created 0600 (umask 077) but it must not retain the secret either.
redact_log_file() {
    [[ -f "$NGROK_LOG" ]] || return 0
    local tmp="${NGROK_LOG}.redacted"
    if redact_secrets < "$NGROK_LOG" > "$tmp" 2>/dev/null; then
        chmod 0600 "$tmp"
        mv -f "$tmp" "$NGROK_LOG"
    else
        rm -f "$tmp"
    fi
}

pid_is_ngrok() {
    local pid="$1"
    [[ -n "$pid" && "$pid" =~ ^[0-9]+$ && -d "/proc/${pid}" ]] || return 1
    local cmdline
    cmdline="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
    [[ "$cmdline" == *ngrok* ]]
}

mkdir -p "$VM_STATE_DIR" "$VM_LOG_DIR"

if ! is_true "$NGROK_ENABLED"; then
    log "ngrok disabled (NGROK_ENABLED=false) - no tunnel will be created"
    exit 0
fi

if [[ -z "${NGROK_AUTHTOKEN}" ]]; then
    if is_true "$NGROK_REQUIRED"; then
        err "NGROK_REQUIRED=true but NGROK_AUTHTOKEN is not set"
        err "add NGROK_AUTHTOKEN as a Render secret environment variable"
        exit 1
    fi
    warn "NGROK_AUTHTOKEN is not set - no tunnel will be created"
    warn "set NGROK_AUTHTOKEN (Render secret) and NGROK_ENABLED=true to enable RDP"
    exit 0
fi

if ! command -v ngrok >/dev/null 2>&1; then
    if is_true "$NGROK_REQUIRED"; then
        err "ngrok binary not found"
        exit 1
    fi
    warn "ngrok binary not found - skipping tunnel"
    exit 0
fi

# Duplicate-instance protection.
if [[ -f "$NGROK_PID_FILE" ]]; then
    existing="$(head -n1 "$NGROK_PID_FILE" 2>/dev/null | tr -dc '0-9' || true)"
    if pid_is_ngrok "$existing"; then
        log "ngrok already running with PID ${existing}"
        exit 0
    fi
    warn "removing stale ngrok PID file"
    rm -f "$NGROK_PID_FILE"
fi

# Parse the requested tunnel list.
IFS=',' read -r -a requested <<<"$NGROK_TUNNELS"
tunnel_names=()
for t in "${requested[@]}"; do
    t="${t//[[:space:]]/}"
    case "$t" in
        rdp|api) tunnel_names+=("$t") ;;
        "") ;;
        *) warn "ignoring unknown tunnel '${t}' (supported: rdp, api)" ;;
    esac
done
if (( ${#tunnel_names[@]} == 0 )); then
    warn "NGROK_TUNNELS contains no valid tunnels - skipping"
    exit 0
fi

# Build the ngrok v3 agent config. Mode 0600 because it contains the token.
umask 077
{
    printf 'version: "3"\n'
    printf 'agent:\n'
    printf '  authtoken: %s\n' "$NGROK_AUTHTOKEN"
    printf '  web_addr: 127.0.0.1:4040\n'
    printf '  log: stdout\n'
    printf '  log_format: json\n'
    printf 'tunnels:\n'
    for t in "${tunnel_names[@]}"; do
        case "$t" in
            rdp)
                printf '  rdp:\n'
                printf '    proto: tcp\n'
                printf '    addr: %s\n' "$NGROK_RDP_ADDR"
                ;;
            api)
                printf '  api:\n'
                printf '    proto: http\n'
                printf '    addr: %s\n' "$NGROK_API_ADDR"
                ;;
        esac
    done
} > "$NGROK_CONFIG"
chmod 0600 "$NGROK_CONFIG"

log "starting tunnel(s): ${tunnel_names[*]}"
for t in "${tunnel_names[@]}"; do
    case "$t" in
        rdp) log "port tunneled: rdp (tcp) -> 127.0.0.1:${NGROK_RDP_ADDR}" ;;
        api) log "port tunneled: api (https) -> 127.0.0.1:${NGROK_API_ADDR}" ;;
    esac
done

: > "$NGROK_LOG"
chmod 0600 "$NGROK_LOG"
nohup ngrok start "${tunnel_names[@]}" \
    --config "$NGROK_CONFIG" \
    --log stdout \
    --log-format json >>"$NGROK_LOG" 2>&1 &
NGROK_PID=$!
printf '%s\n' "$NGROK_PID" > "$NGROK_PID_FILE"

# Wait for the local ngrok API and persist the public URLs.
deadline=$((SECONDS + NGROK_START_TIMEOUT))
urls_ready=false
while (( SECONDS < deadline )); do
    if ! pid_is_ngrok "$NGROK_PID"; then
        err "ngrok exited during startup - see ${NGROK_LOG}"
        redact_log_file
        tail -n 20 "$NGROK_LOG" >&2 || true
        rm -f "$NGROK_PID_FILE"
        if is_true "$NGROK_REQUIRED"; then
            exit 1
        fi
        exit 0
    fi
    if curl -fsS --connect-timeout 2 --max-time 5 \
            "http://127.0.0.1:4040/api/tunnels" -o "${VM_STATE_DIR}/ngrok-api.json" 2>/dev/null; then
        if jq -e '.tunnels | length > 0' "${VM_STATE_DIR}/ngrok-api.json" >/dev/null 2>&1; then
            urls_ready=true
            break
        fi
    fi
    sleep 2
done

if [[ "$urls_ready" == "true" ]]; then
    python3 - "$NGROK_URLS" "${VM_STATE_DIR}/ngrok-api.json" <<'PY'
import json
import sys
from datetime import datetime, timezone

out_path, api_path = sys.argv[1], sys.argv[2]
with open(api_path, encoding="utf-8") as fh:
    data = json.load(fh)
tunnels = {}
for tunnel in data.get("tunnels", []):
    name = tunnel.get("name")
    if name:
        tunnels[name] = tunnel.get("public_url")
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump({
        "started_at": datetime.now(timezone.utc).isoformat(),
        "tunnels": tunnels,
    }, fh, indent=2)
print("[NGROK] public endpoints:")
for name, url in tunnels.items():
    if name == "rdp" and url:
        # tcp://host:port -> host:port for RDP clients
        print(f"[NGROK]   RDP  -> {url.replace('tcp://', '')}")
    else:
        print(f"[NGROK]   {name.upper()} -> {url}")
PY
else
    redact_log_file
    warn "ngrok did not report public URLs within ${NGROK_START_TIMEOUT}s"
    warn "check ${NGROK_LOG}"
    if is_true "$NGROK_REQUIRED"; then
        exit 1
    fi
fi

log "ngrok tunnel started (PID ${NGROK_PID})"
exit 0
