#!/usr/bin/env bash
# =============================================================================
# scripts/entrypoint.sh
#
# Container entrypoint / supervisor for the Windows 10 VM on Render.
#
# Startup sequence:
#   1.  Validate environment variables
#   2.  Optional DEBUG_MODE diagnostics (no secrets)
#   3.  Check /dev/kvm and probe QEMU KVM acceleration
#   4.  Start the status/health HTTP API (so Render detects the open port
#       immediately, even while installation media is being downloaded)
#   5.  Validate the persistent disk mount
#   6.  Prepare/verify the QCOW2 disk and UEFI variable store
#   7.  Start QEMU (unless KVM_TEST_ONLY / VM_AUTOSTART=false)
#   8.  Wait for VM availability
#   9.  Start the ngrok tunnel(s)
#   10. Report status and supervise children; shut down cleanly on SIGTERM/SIGINT
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

VM_DATA_DIR="${VM_DATA_DIR:-/var/lib/windows}"
VM_DISK="${VM_DISK:-${VM_DATA_DIR}/windows10.qcow2}"
OVMF_VARS="${OVMF_VARS:-${VM_DATA_DIR}/uefi/OVMF_VARS.fd}"
VM_STATE_DIR="${VM_STATE_DIR:-/run/windows-vm}"
VM_LOG_DIR="${VM_LOG_DIR:-/var/log/windows-vm}"
VM_CPUS="${VM_CPUS:-6}"
VM_MEMORY_MB="${VM_MEMORY_MB:-22528}"
VM_AUTOSTART="${VM_AUTOSTART:-false}"
KVM_TEST_ONLY="${KVM_TEST_ONLY:-false}"
KVM_REQUIRED="${KVM_REQUIRED:-true}"
ENABLE_TCG_FALLBACK="${ENABLE_TCG_FALLBACK:-false}"
DEBUG_MODE="${DEBUG_MODE:-false}"
PORT="${PORT:-10000}"

KVM_JSON="${VM_STATE_DIR}/kvm-status.json"
NGROK_PID_FILE="${VM_STATE_DIR}/ngrok.pid"
STARTED_AT_FILE="${VM_STATE_DIR}/service-started-at"

mkdir -p "$VM_STATE_DIR" "$VM_LOG_DIR"

log() {
    local tag="$1"; shift
    printf '[%s] %s\n' "$tag" "$*"
}

is_true() {
    case "${1,,}" in
        true|1|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

require_bool() {
    local name="$1" value="${2:-}"
    case "${value,,}" in
        true|false|1|0|yes|no|on|off) ;;
        *) log ERROR "${name} must be a boolean, got '${value}'"; exit 1 ;;
    esac
}

require_int() {
    local name="$1" value="$2" min="$3" max="$4"
    [[ "$value" =~ ^[0-9]+$ ]] || { log ERROR "${name} must be an integer, got '${value}'"; exit 1; }
    (( value >= min && value <= max )) || { log ERROR "${name} out of range ${min}-${max}: ${value}"; exit 1; }
}

# ---------------------------------------------------------------------------
# 1. Environment validation
# ---------------------------------------------------------------------------
validate_environment() {
    log BOOT "Validating environment"
    require_int VM_MEMORY_MB "$VM_MEMORY_MB" 1024 1048576
    require_int VM_CPUS "$VM_CPUS" 1 128
    require_int PORT "$PORT" 1 65535
    require_bool KVM_REQUIRED "$KVM_REQUIRED"
    require_bool ENABLE_TCG_FALLBACK "$ENABLE_TCG_FALLBACK"
    require_bool VM_AUTOSTART "$VM_AUTOSTART"
    require_bool KVM_TEST_ONLY "$KVM_TEST_ONLY"
    require_bool DEBUG_MODE "$DEBUG_MODE"

    if [[ -n "${VM_MAC:-}" && ! "${VM_MAC}" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]; then
        log ERROR "VM_MAC is not a valid MAC address"
        exit 1
    fi

    # The system disk and UEFI variables must live on the persistent disk.
    if [[ "$VM_DISK" != "${VM_DATA_DIR}/"* ]]; then
        log ERROR "VM_DISK must live under VM_DATA_DIR (${VM_DATA_DIR}), got ${VM_DISK}"
        exit 1
    fi
    if [[ "$OVMF_VARS" != "${VM_DATA_DIR}/"* ]]; then
        log ERROR "OVMF_VARS must live under VM_DATA_DIR (${VM_DATA_DIR}), got ${OVMF_VARS}"
        exit 1
    fi
    log BOOT "Environment OK (VM: ${VM_CPUS} vCPU / ${VM_MEMORY_MB} MB RAM, autostart=${VM_AUTOSTART}, kvm_test_only=${KVM_TEST_ONLY})"
}

# ---------------------------------------------------------------------------
# DEBUG_MODE diagnostics (never prints secrets)
# ---------------------------------------------------------------------------
debug_dump() {
    is_true "$DEBUG_MODE" || return 0
    log DEBUG "===== diagnostics start ====="
    uname -a || true
    printf '[DEBUG] os-release: %s\n' "$(grep -E '^PRETTY_NAME' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"' || echo unknown)"
    printf '[DEBUG] cpus: %s\n' "$(nproc 2>/dev/null || echo unknown)"
    printf '[DEBUG] memory:\n'
    free -h 2>/dev/null || true
    printf '[DEBUG] /dev/kvm:\n'
    ls -l /dev/kvm 2>&1 || true
    printf '[DEBUG] cpu virtualization flags: %s\n' "$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | grep -oE '(vmx|svm|hypervisor)' | sort -u | tr '\n' ' ' || echo none)"
    printf '[DEBUG] qemu: %s\n' "$(qemu-system-x86_64 --version 2>/dev/null | head -n1 || echo missing)"
    printf '[DEBUG] ovmf files:\n'
    find /usr/share/OVMF -maxdepth 1 -type f 2>/dev/null | head -n 20 || true
    printf '[DEBUG] disk usage %s:\n' "$VM_DATA_DIR"
    df -h "$VM_DATA_DIR" 2>/dev/null || true
    if [[ -f "$VM_DISK" ]]; then
        qemu-img info "$VM_DISK" 2>/dev/null || true
    fi
    printf '[DEBUG] ngrok: %s\n' "$(ngrok version 2>/dev/null | head -n1 || echo missing)"
    printf '[DEBUG] network:\n'
    ip -brief address 2>/dev/null || true
    ip route 2>/dev/null || true
    printf '[DEBUG] safe environment snapshot:\n'
    env | grep -E '^(RENDER|IS_RENDER|VM_|KVM_|ENABLE_TCG|DEBUG_MODE|PORT|STATUS_API_BIND|NGROK_ENABLED|NGROK_REQUIRED|NGROK_TUNNELS)' \
        | grep -viE '(TOKEN|SECRET|PASSWORD|PASSWD|KEY|CREDENTIAL)' \
        | sort || true
    log DEBUG "===== diagnostics end ====="
}

# ---------------------------------------------------------------------------
# 3. KVM capability check
# ---------------------------------------------------------------------------
run_kvm_check() {
    log KVM "Checking /dev/kvm"
    set +e
    "$SCRIPT_DIR/check-kvm.sh" --json | tee "$KVM_JSON"
    KVM_RC=${PIPESTATUS[0]}
    set -e
    if (( KVM_RC == 0 )); then
        KVM_AVAILABLE=true
        log KVM "AVAILABLE"
    else
        KVM_AVAILABLE=false
        log KVM "NOT AVAILABLE"
        log KVM "Details: $(jq -r '.reason' "$KVM_JSON" 2>/dev/null || echo 'see log')"
    fi
}

# ---------------------------------------------------------------------------
# 6. VM start decision
# ---------------------------------------------------------------------------
start_vm_if_requested() {
    if is_true "$KVM_TEST_ONLY"; then
        log BOOT "KVM_TEST_ONLY=true - diagnostics complete, Windows will NOT be started"
        log BOOT "set KVM_TEST_ONLY=false and VM_AUTOSTART=true to boot the VM"
        return 0
    fi

    if ! is_true "$VM_AUTOSTART"; then
        log BOOT "VM_AUTOSTART=false - Windows will NOT be started automatically"
        log BOOT "run 'start-vm' inside the service shell or set VM_AUTOSTART=true"
        return 0
    fi

    if [[ "${KVM_AVAILABLE}" != "true" ]]; then
        if is_true "$ENABLE_TCG_FALLBACK"; then
            log ERROR "KVM UNAVAILABLE - USING TCG SOFTWARE EMULATION (explicit opt-in)"
        else
            log ERROR "KVM is required but /dev/kvm is unavailable"
            log ERROR "Windows VM will not start"
            log ERROR "verify /dev/kvm on the selected Render service; Render does not document KVM passthrough for Docker services"
            log ERROR "set ENABLE_TCG_FALLBACK=true to explicitly accept slow TCG emulation"
            exit 1
        fi
    fi

    log QEMU "Starting Windows 10"
    "$SCRIPT_DIR/start-vm.sh"
    log VM "Running"
}

# ---------------------------------------------------------------------------
# 4. Status API
# ---------------------------------------------------------------------------
start_status_server() {
    log BOOT "Starting status/health API on 0.0.0.0:${PORT}"
    python3 "${APP_DIR}/server/status_server.py" >>"$VM_LOG_DIR/status-server.log" 2>&1 &
    STATUS_PID=$!
    sleep 1
    if ! kill -0 "$STATUS_PID" 2>/dev/null; then
        log ERROR "status server failed to start - see ${VM_LOG_DIR}/status-server.log"
        exit 1
    fi
    log BOOT "status server PID ${STATUS_PID}"
}

# ---------------------------------------------------------------------------
# Shutdown
# ---------------------------------------------------------------------------
STATUS_PID=""
SHUTTING_DOWN=false

stop_ngrok() {
    if [[ -f "$NGROK_PID_FILE" ]]; then
        local pid
        pid="$(head -n1 "$NGROK_PID_FILE" 2>/dev/null | tr -dc '0-9' || true)"
        if [[ -n "$pid" && -d "/proc/${pid}" ]]; then
            log NGROK "Stopping tunnel (PID ${pid})"
            kill -TERM "$pid" 2>/dev/null || true
            for _ in {1..10}; do
                [[ -d "/proc/${pid}" ]] || break
                sleep 1
            done
            kill -KILL "$pid" 2>/dev/null || true
        fi
        rm -f "$NGROK_PID_FILE"
    fi
}

shutdown() {
    local exit_code="${1:-0}"
    if [[ "$SHUTTING_DOWN" == "true" ]]; then
        return 0
    fi
    SHUTTING_DOWN=true
    trap - TERM INT
    log BOOT "Shutdown requested - stopping services gracefully"

    if [[ -n "$STATUS_PID" ]] && kill -0 "$STATUS_PID" 2>/dev/null; then
        kill -TERM "$STATUS_PID" 2>/dev/null || true
    fi

    stop_ngrok

    if [[ -x "$SCRIPT_DIR/stop-vm.sh" ]] && [[ -f "${VM_STATE_DIR}/qemu.pid" ]]; then
        "$SCRIPT_DIR/stop-vm.sh" || log ERROR "stop-vm.sh reported an error"
    fi

    log BOOT "Shutdown complete"
    exit "$exit_code"
}

trap 'shutdown 0' TERM INT

# ---------------------------------------------------------------------------
# Main sequence
# ---------------------------------------------------------------------------
validate_environment
debug_dump

log BOOT "Starting Windows VM service"
log BOOT "container runtime: pid=$$, port=${PORT}"

run_kvm_check

# Start the status API early: Render scans the container for an open port
# right after startup, and setup-disk.sh can block for a long time while
# downloading administrator-supplied installation media.
date -u +%Y-%m-%dT%H:%M:%SZ > "${STARTED_AT_FILE}.iso"
date -u +%s > "$STARTED_AT_FILE"
start_status_server

log DISK "Checking ${VM_DISK}"
if ! "$SCRIPT_DIR/setup-disk.sh"; then
    log ERROR "persistent storage setup failed"
    exit 1
fi

start_vm_if_requested

if is_true "${NGROK_ENABLED:-false}"; then
    log NGROK "Starting tunnel"
    if ! "$SCRIPT_DIR/start-ngrok.sh"; then
        log ERROR "ngrok tunnel failed"
        if is_true "${NGROK_REQUIRED:-false}"; then
            exit 1
        fi
    fi
else
    log NGROK "Tunnel disabled (NGROK_ENABLED=false)"
fi

# Report final state.
if [[ -x "$SCRIPT_DIR/check-vm.sh" ]] && "$SCRIPT_DIR/check-vm.sh" >/dev/null 2>&1; then
    log VM "Running"
else
    log VM "Not running (see status endpoint)"
fi
log BOOT "Service ready - health: http://127.0.0.1:${PORT}/health"

# Supervise: if the status server dies, terminate the container so Render
# restarts it. Signals are handled by the trap above.
wait "$STATUS_PID" || true
log ERROR "status server exited unexpectedly"
shutdown 1
