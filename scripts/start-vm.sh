#!/usr/bin/env bash
# =============================================================================
# scripts/start-vm.sh
#
# Builds and launches the Windows 10 QEMU command.
#
#   - detects KVM availability (via check-kvm.sh)
#   - refuses to start when KVM is required but unavailable
#   - uses the TCG software emulator only when ENABLE_TCG_FALLBACK=true
#   - prevents duplicate QEMU instances (PID file + process identity check)
#   - uses UEFI/OVMF, VirtIO disk/NIC, Q35 machine, host CPU passthrough
#   - exposes RDP only on 127.0.0.1 (reached through ngrok)
#   - QEMU monitor/QMP use unix sockets, never TCP
#
# Exit codes:
#   0 -> QEMU started (or already running)
#   1 -> start failed
#   2 -> KVM required but unavailable
# =============================================================================
set -Eeuo pipefail

VM_DATA_DIR="${VM_DATA_DIR:-/var/lib/windows}"
VM_DISK="${VM_DISK:-${VM_DATA_DIR}/windows10.qcow2}"
VM_CPUS="${VM_CPUS:-6}"
VM_MEMORY_MB="${VM_MEMORY_MB:-22528}"
VM_NAME="${VM_NAME:-windows10}"
VM_MACHINE="${VM_MACHINE:-q35}"
VM_CPU_MODEL="${VM_CPU_MODEL:-host}"
VM_CPU_MODEL_TCG="${VM_CPU_MODEL_TCG:-max}"
VM_DISK_BUS="${VM_DISK_BUS:-virtio}"
VM_DISK_CACHE="${VM_DISK_CACHE:-writeback}"
WINDOWS_ISO="${WINDOWS_ISO:-${VM_DATA_DIR}/iso/windows10.iso}"
VIRTIO_ISO="${VIRTIO_ISO:-${VM_DATA_DIR}/iso/virtio-win.iso}"
VM_BOOT_DEVICE="${VM_BOOT_DEVICE:-auto}"
VM_INSTALL_MARKER="${VM_INSTALL_MARKER:-${VM_DATA_DIR}/state/windows_installed}"
OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
OVMF_VARS="${OVMF_VARS:-${VM_DATA_DIR}/uefi/OVMF_VARS.fd}"
VM_HOSTFWD_RDP="${VM_HOSTFWD_RDP:-3389}"
VM_MAC="${VM_MAC:-}"
VM_VGA="${VM_VGA:-std}"
VM_DISPLAY="${VM_DISPLAY:-none}"
VM_USB_TABLET="${VM_USB_TABLET:-true}"
VM_STATE_DIR="${VM_STATE_DIR:-/run/windows-vm}"
VM_LOG_DIR="${VM_LOG_DIR:-/var/log/windows-vm}"
VM_START_TIMEOUT="${VM_START_TIMEOUT:-180}"
VM_MONITOR_TIMEOUT="${VM_MONITOR_TIMEOUT:-10}"
KVM_REQUIRED="${KVM_REQUIRED:-true}"
ENABLE_TCG_FALLBACK="${ENABLE_TCG_FALLBACK:-false}"

PID_FILE="${VM_STATE_DIR}/qemu.pid"
MONITOR_SOCK="${VM_STATE_DIR}/monitor.sock"
QMP_SOCK="${VM_STATE_DIR}/qmp.sock"
LOCK_FILE="${VM_STATE_DIR}/start.lock"
QEMU_LOG="${VM_LOG_DIR}/qemu-console.log"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$VM_STATE_DIR" "$VM_LOG_DIR"

log()  { printf '[QEMU] %s\n' "$*"; }
warn() { printf '[QEMU][WARN] %s\n' "$*" >&2; }
err()  { printf '[QEMU][ERROR] %s\n' "$*" >&2; }

is_true() {
    case "${1,,}" in
        true|1|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# PID helpers
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
validate_environment() {
    [[ "$VM_CPUS" =~ ^[0-9]+$ ]] || { err "VM_CPUS must be an integer"; exit 1; }
    (( VM_CPUS >= 1 && VM_CPUS <= 128 )) || { err "VM_CPUS out of range (1-128)"; exit 1; }
    [[ "$VM_MEMORY_MB" =~ ^[0-9]+$ ]] || { err "VM_MEMORY_MB must be an integer"; exit 1; }
    (( VM_MEMORY_MB >= 1024 && VM_MEMORY_MB <= 1048576 )) || { err "VM_MEMORY_MB out of range (1024-1048576)"; exit 1; }
    [[ -n "$VM_NAME" ]] || { err "VM_NAME must not be empty"; exit 1; }

    case "$VM_DISK_BUS" in
        virtio|sata) ;;
        *) err "VM_DISK_BUS must be 'virtio' or 'sata'"; exit 1 ;;
    esac
    case "$VM_DISK_CACHE" in
        none|writeback|writethrough|directsync|unsafe) ;;
        *) err "VM_DISK_CACHE invalid: $VM_DISK_CACHE"; exit 1 ;;
    esac
    if [[ -n "$VM_MAC" && ! "$VM_MAC" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]; then
        err "VM_MAC is not a valid MAC address"; exit 1
    fi
    [[ "$VM_HOSTFWD_RDP" =~ ^[0-9]+$ ]] || { err "VM_HOSTFWD_RDP must be a port number"; exit 1; }

    [[ -f "$VM_DISK" ]] || { err "disk ${VM_DISK} does not exist (run scripts/setup-disk.sh)"; exit 1; }
    [[ -f "$OVMF_VARS" ]] || { err "UEFI variable store ${OVMF_VARS} missing (run scripts/setup-disk.sh)"; exit 1; }

    local fw
    for fw in "$OVMF_CODE" /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do
        if [[ -f "$fw" ]]; then
            OVMF_CODE="$fw"
            break
        fi
    done
    [[ -f "$OVMF_CODE" ]] || { err "OVMF firmware not found (install 'ovmf')"; exit 1; }

    command -v qemu-system-x86_64 >/dev/null 2>&1 || { err "qemu-system-x86_64 not found"; exit 1; }
}

# ---------------------------------------------------------------------------
# KVM decision
# ---------------------------------------------------------------------------
decide_acceleration() {
    if "$SCRIPT_DIR/check-kvm.sh" >/dev/null 2>&1; then
        ACCEL="kvm"
        log "KVM acceleration enabled (-accel kvm -cpu ${VM_CPU_MODEL})"
        return 0
    fi

    log "KVM NOT AVAILABLE"

    if is_true "$ENABLE_TCG_FALLBACK"; then
        ACCEL="tcg"
        warn "KVM UNAVAILABLE - USING TCG SOFTWARE EMULATION (very slow, explicit opt-in)"
        return 0
    fi

    if is_true "$KVM_REQUIRED"; then
        err "KVM is required but /dev/kvm is unavailable"
        err "Windows VM will not start"
        err "verify that /dev/kvm is present on this Render service/host"
        err "or set KVM_REQUIRED=false and ENABLE_TCG_FALLBACK=true to accept TCG"
        exit 2
    fi

    err "KVM unavailable and TCG fallback not enabled"
    exit 2
}

# ---------------------------------------------------------------------------
# Monitor helpers
# ---------------------------------------------------------------------------
monitor_cmd() {
    local cmd="$1"
    timeout "$VM_MONITOR_TIMEOUT" socat - "UNIX-CONNECT:${MONITOR_SOCK}" <<<"$cmd" 2>/dev/null
}

wait_for_monitor() {
    local deadline=$((SECONDS + VM_MONITOR_TIMEOUT))
    while (( SECONDS < deadline )); do
        if [[ -S "$MONITOR_SOCK" ]] && monitor_cmd "info status" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
validate_environment
decide_acceleration

# Duplicate-instance protection. The lock covers the check+write window; once
# the PID file points at a live QEMU process, later invocations exit early.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    err "another start-vm.sh invocation is in progress"
    exit 1
fi

if existing_pid="$(read_pid_file)"; then
    if pid_is_our_qemu "$existing_pid"; then
        log "QEMU already running with PID ${existing_pid} - nothing to do"
        exit 0
    fi
    warn "removing stale PID file (PID ${existing_pid} is not a running QEMU)"
    rm -f "$PID_FILE"
fi

# Clean stale monitor sockets left behind by a crashed QEMU.
rm -f "$MONITOR_SOCK" "$QMP_SOCK"

QEMU_ARGS=()
QEMU_ARGS+=(-name "guest=${VM_NAME},process=${VM_NAME}")
QEMU_ARGS+=(-machine "${VM_MACHINE},accel=${ACCEL}")
if [[ "$ACCEL" == "kvm" ]]; then
    QEMU_ARGS+=(-cpu "$VM_CPU_MODEL")
else
    QEMU_ARGS+=(-cpu "$VM_CPU_MODEL_TCG")
fi
QEMU_ARGS+=(-smp "${VM_CPUS},sockets=1,cores=${VM_CPUS},threads=1")
QEMU_ARGS+=(-m "$VM_MEMORY_MB")

# UEFI/OVMF firmware and persistent per-VM variable store.
QEMU_ARGS+=(-drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}")
QEMU_ARGS+=(-drive "if=pflash,format=raw,file=${OVMF_VARS}")

# AHCI controller - used for CD-ROM devices and optionally the system disk.
QEMU_ARGS+=(-device "ich9-ahci,id=ahci")

# System disk.
case "$VM_DISK_BUS" in
    virtio)
        # VirtIO block: best performance with virtio-win drivers.
        QEMU_ARGS+=(-drive "file=${VM_DISK},if=none,id=disk0,format=qcow2,cache=${VM_DISK_CACHE},discard=unmap")
        QEMU_ARGS+=(-device "virtio-blk-pci,drive=disk0,id=disk0,bootindex=1")
        ;;
    sata)
        QEMU_ARGS+=(-drive "file=${VM_DISK},if=none,id=disk0,format=qcow2,cache=${VM_DISK_CACHE}")
        QEMU_ARGS+=(-device "ide-hd,drive=disk0,bus=ahci.0,bootindex=1")
        ;;
esac

# Installation media (CD-ROM). Missing ISOs are simply not attached.
if [[ -f "$WINDOWS_ISO" ]]; then
    QEMU_ARGS+=(-drive "file=${WINDOWS_ISO},if=none,id=cd0,media=cdrom,readonly=on,format=raw")
    QEMU_ARGS+=(-device "ide-cd,drive=cd0,bus=ahci.1")
else
    warn "Windows installation ISO not found at ${WINDOWS_ISO} - no CD-ROM attached"
fi
if [[ -f "$VIRTIO_ISO" ]]; then
    QEMU_ARGS+=(-drive "file=${VIRTIO_ISO},if=none,id=cd1,media=cdrom,readonly=on,format=raw")
    QEMU_ARGS+=(-device "ide-cd,drive=cd1,bus=ahci.2")
fi

# Boot order: install from CD when no installation marker exists yet.
if [[ -f "$VM_INSTALL_MARKER" || "$VM_BOOT_DEVICE" == "disk" ]]; then
    log "boot device: persistent disk"
    QEMU_ARGS+=(-boot "order=c,menu=on")
elif [[ "$VM_BOOT_DEVICE" == "cdrom" || ( "$VM_BOOT_DEVICE" == "auto" && -f "$WINDOWS_ISO" ) ]]; then
    log "boot device: CD-ROM (Windows installation)"
    QEMU_ARGS+=(-boot "order=d,menu=on")
else
    log "boot device: persistent disk (no installation media)"
    QEMU_ARGS+=(-boot "order=c,menu=on")
fi

# Networking: user mode (SLIRP). RDP is forwarded to 127.0.0.1 only, so
# nothing is reachable from the public internet without ngrok.
QEMU_ARGS+=(-netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${VM_HOSTFWD_RDP}-:3389")
if [[ -n "$VM_MAC" ]]; then
    QEMU_ARGS+=(-device "virtio-net-pci,netdev=net0,mac=${VM_MAC}")
else
    QEMU_ARGS+=(-device "virtio-net-pci,netdev=net0")
fi

# Entropy source (Windows benefits from virtio-rng).
QEMU_ARGS+=(-object "rng-random,filename=/dev/urandom,id=rng0")
QEMU_ARGS+=(-device "virtio-rng-pci,rng=rng0")

# Display: headless container, Windows desktop is consumed over RDP.
QEMU_ARGS+=(-vga "$VM_VGA")
QEMU_ARGS+=(-display "$VM_DISPLAY")

# Input: absolute pointing device for a usable desktop.
if is_true "$VM_USB_TABLET"; then
    QEMU_ARGS+=(-device "qemu-xhci,id=xhci")
    QEMU_ARGS+=(-device "usb-tablet,bus=xhci.0")
fi

# Clock: Windows expects local time.
QEMU_ARGS+=(-rtc "base=localtime,clock=host")

# Management interfaces - unix sockets on the private /run tmpfs only.
QEMU_ARGS+=(-monitor "unix:${MONITOR_SOCK},server,nowait")
QEMU_ARGS+=(-qmp "unix:${QMP_SOCK},server,nowait")
QEMU_ARGS+=(-D "${VM_LOG_DIR}/qemu-debug.log")
QEMU_ARGS+=(-msg "timestamp=on")

# ---------------------------------------------------------------------------
# Launch
# ---------------------------------------------------------------------------
log "Starting Windows 10 (PID file: ${PID_FILE})"
log "command: qemu-system-x86_64 ${QEMU_ARGS[*]}"

: > "$QEMU_LOG"
nohup qemu-system-x86_64 "${QEMU_ARGS[@]}" >>"$QEMU_LOG" 2>&1 &
QEMU_PID=$!

# A running process must still be alive after a short grace period.
sleep 2
if ! pid_is_our_qemu "$QEMU_PID"; then
    err "QEMU exited immediately - see ${QEMU_LOG}"
    tail -n 40 "$QEMU_LOG" >&2 || true
    exit 1
fi

printf '%s\n' "$QEMU_PID" > "$PID_FILE"

if ! wait_for_monitor; then
    warn "QEMU monitor did not answer within ${VM_MONITOR_TIMEOUT}s"
fi

# Wait until the VM reports a live state (or timeout).
deadline=$((SECONDS + VM_START_TIMEOUT))
state="unknown"
while (( SECONDS < deadline )); do
    if ! pid_is_our_qemu "$QEMU_PID"; then
        err "QEMU died during startup - see ${QEMU_LOG}"
        tail -n 40 "$QEMU_LOG" >&2 || true
        rm -f "$PID_FILE"
        exit 1
    fi
    out="$(monitor_cmd 'info status' | tr -d '\r' || true)"
    state="$(printf '%s' "$out" | sed -n 's/^VM status: //p' | head -n1)"
    if [[ "$state" == "running" || "$state" == "paused" ]]; then
        break
    fi
    sleep 2
done

if [[ "$ACCEL" == "kvm" ]]; then
    log "KVM acceleration enabled"
else
    warn "KVM UNAVAILABLE - USING TCG SOFTWARE EMULATION"
fi
log "VM ${VM_NAME} status: ${state:-unknown} (PID ${QEMU_PID})"
log "RDP forwarded to 127.0.0.1:${VM_HOSTFWD_RDP} (tunnel only, not public)"
exit 0
