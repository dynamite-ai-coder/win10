#!/usr/bin/env bash
# =============================================================================
# scripts/stop-vm.sh
#
# Gracefully stops the Windows 10 VM:
#   1. ACPI shutdown request through the QEMU monitor (system_powerdown)
#   2. wait VM_SHUTDOWN_TIMEOUT seconds
#   3. QEMU "quit" through the monitor
#   4. SIGTERM
#   5. SIGKILL as a last resort
#
# Safe to run when no VM is running (exit 0). Never kills unrelated PIDs.
# =============================================================================
set -Eeuo pipefail

VM_STATE_DIR="${VM_STATE_DIR:-/run/windows-vm}"
VM_SHUTDOWN_TIMEOUT="${VM_SHUTDOWN_TIMEOUT:-180}"
VM_MONITOR_TIMEOUT="${VM_MONITOR_TIMEOUT:-10}"
PID_FILE="${VM_STATE_DIR}/qemu.pid"
MONITOR_SOCK="${VM_STATE_DIR}/monitor.sock"
QMP_SOCK="${VM_STATE_DIR}/qmp.sock"

log()  { printf '[QEMU] %s\n' "$*"; }
warn() { printf '[QEMU][WARN] %s\n' "$*" >&2; }

mkdir -p "$VM_STATE_DIR"

pid_is_our_qemu() {
    local pid="$1"
    [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 1
    [[ -d "/proc/${pid}" ]] || return 1
    local cmdline=""
    cmdline="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
    [[ "$cmdline" == *qemu-system-x86_64* ]]
}

read_pid_file() {
    [[ -f "$PID_FILE" ]] || return 1
    local pid
    pid="$(head -n1 "$PID_FILE" 2>/dev/null | tr -dc '0-9')"
    [[ -n "$pid" ]] || return 1
    printf '%s' "$pid"
}

monitor_cmd() {
    timeout "$VM_MONITOR_TIMEOUT" socat - "UNIX-CONNECT:${MONITOR_SOCK}" <<<"$1" 2>/dev/null || true
}

wait_for_exit() {
    local pid="$1" remaining="$2"
    while (( remaining > 0 )); do
        if ! pid_is_our_qemu "$pid"; then
            return 0
        fi
        sleep 1
        remaining=$((remaining - 1))
    done
    return 1
}

if ! pid="$(read_pid_file)"; then
    log "no PID file - VM is not running"
    rm -f "$MONITOR_SOCK" "$QMP_SOCK"
    exit 0
fi

if ! pid_is_our_qemu "$pid"; then
    warn "stale PID file (PID ${pid}) - removing"
    rm -f "$PID_FILE"
    rm -f "$MONITOR_SOCK" "$QMP_SOCK"
    exit 0
fi

log "stopping QEMU PID ${pid}"

# 1. ACPI shutdown - lets Windows flush its filesystem and power off cleanly.
if [[ -S "$MONITOR_SOCK" ]]; then
    resp="$(monitor_cmd 'system_powerdown')"
    if [[ -n "$resp" ]]; then
        log "ACPI powerdown requested"
    else
        warn "no response from QEMU monitor, continuing"
    fi
else
    warn "QEMU monitor socket not found"
fi

if wait_for_exit "$pid" "$VM_SHUTDOWN_TIMEOUT"; then
    log "QEMU exited after ACPI shutdown"
    rm -f "$PID_FILE" "$MONITOR_SOCK" "$QMP_SOCK"
    exit 0
fi

# 2. Hard QEMU quit.
warn "VM did not shut down within ${VM_SHUTDOWN_TIMEOUT}s - sending monitor quit"
if [[ -S "$MONITOR_SOCK" ]]; then
    monitor_cmd 'quit' >/dev/null || true
fi
if wait_for_exit "$pid" 20; then
    log "QEMU exited after monitor quit"
    rm -f "$PID_FILE" "$MONITOR_SOCK" "$QMP_SOCK"
    exit 0
fi

# 3. SIGTERM.
warn "sending SIGTERM to QEMU ${pid}"
kill -TERM "$pid" 2>/dev/null || true
if wait_for_exit "$pid" 20; then
    log "QEMU exited after SIGTERM"
    rm -f "$PID_FILE" "$MONITOR_SOCK" "$QMP_SOCK"
    exit 0
fi

# 4. SIGKILL - last resort, filesystem integrity may be at risk.
warn "sending SIGKILL to QEMU ${pid}"
kill -KILL "$pid" 2>/dev/null || true
sleep 2
rm -f "$PID_FILE" "$MONITOR_SOCK" "$QMP_SOCK"
log "QEMU stopped (forced)"
exit 0
