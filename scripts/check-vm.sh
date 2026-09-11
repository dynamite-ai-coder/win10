#!/usr/bin/env bash
# =============================================================================
# scripts/check-vm.sh
#
# Reports whether the QEMU process and the Windows VM are running.
#
# Usage:
#   check-vm.sh          # human readable
#   check-vm.sh --json   # machine readable JSON on stdout
#
# Exit codes:
#   0 -> VM running
#   1 -> VM not running
# =============================================================================
set -Eeuo pipefail

JSON_MODE=false
if [[ "${1:-}" == "--json" ]]; then
    JSON_MODE=true
elif [[ -n "${1:-}" ]]; then
    echo "usage: $0 [--json]" >&2
    exit 1
fi

VM_NAME="${VM_NAME:-windows10}"
VM_STATE_DIR="${VM_STATE_DIR:-/run/windows-vm}"
VM_MONITOR_TIMEOUT="${VM_MONITOR_TIMEOUT:-5}"
PID_FILE="${VM_STATE_DIR}/qemu.pid"
MONITOR_SOCK="${VM_STATE_DIR}/monitor.sock"

log() {
    if [[ "$JSON_MODE" == "true" ]]; then
        printf '[VM] %s\n' "$*" >&2
    else
        printf '[VM] %s\n' "$*"
    fi
}

pid=""
running=false
qemu_status="stopped"
pid_file_present=false
pid_file_valid=false

if [[ -f "$PID_FILE" ]]; then
    pid_file_present=true
    pid="$(head -n1 "$PID_FILE" 2>/dev/null | tr -dc '0-9')"
fi

if [[ -n "$pid" && "$pid" =~ ^[0-9]+$ && -d "/proc/${pid}" ]]; then
    cmdline="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
    if [[ "$cmdline" == *qemu-system-x86_64* ]]; then
        pid_file_valid=true
        running=true
        log "QEMU process alive (PID ${pid})"
        if [[ -S "$MONITOR_SOCK" ]]; then
            out="$(timeout "$VM_MONITOR_TIMEOUT" socat - "UNIX-CONNECT:${MONITOR_SOCK}" <<<'info status' 2>/dev/null | tr -d '\r' || true)"
            parsed="$(printf '%s' "$out" | sed -n 's/^VM status: //p' | head -n1)"
            [[ -n "$parsed" ]] && qemu_status="$parsed"
            log "QEMU monitor status: ${qemu_status}"
        else
            log "QEMU monitor socket not available"
        fi
    else
        log "PID ${pid} is not a QEMU process (stale PID file)"
    fi
else
    log "QEMU is not running"
fi

if [[ "$JSON_MODE" == "true" ]]; then
    export VM_NAME PID_FILE MONITOR_SOCK PID="$pid" RUNNING="$running"
    export QEMU_STATUS="$qemu_status" PID_FILE_PRESENT="$pid_file_present" PID_FILE_VALID="$pid_file_valid"
    python3 - <<'PY'
import json
import os

def b(name):
    return os.environ.get(name) == "true"

pid = os.environ.get("PID") or None
print(json.dumps({
    "vm_name": os.environ.get("VM_NAME"),
    "running": b("RUNNING"),
    "status": "running" if b("RUNNING") else "stopped",
    "qemu_status": os.environ.get("QEMU_STATUS"),
    "pid": int(pid) if pid and pid.isdigit() else None,
    "pid_file": os.environ.get("PID_FILE"),
    "pid_file_present": b("PID_FILE_PRESENT"),
    "pid_file_valid": b("PID_FILE_VALID"),
    "monitor_socket": os.environ.get("MONITOR_SOCK"),
}, indent=2))
PY
fi

if [[ "$running" == "true" ]]; then
    exit 0
fi
exit 1
