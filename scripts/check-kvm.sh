#!/usr/bin/env bash
# =============================================================================
# scripts/check-kvm.sh
#
# Determines whether /dev/kvm exists and whether QEMU can actually use KVM
# hardware acceleration on this host. This is the single source of truth for
# KVM availability in the project.
#
# Usage:
#   check-kvm.sh            # human readable report, exit 0 = available
#   check-kvm.sh --json     # machine readable JSON on stdout, logs on stderr
#
# Exit codes:
#   0 -> KVM AVAILABLE
#   1 -> KVM NOT AVAILABLE
#   2 -> diagnostic error (unexpected failure)
# =============================================================================
set -Eeuo pipefail

JSON_MODE=false
if [[ "${1:-}" == "--json" ]]; then
    JSON_MODE=true
elif [[ -n "${1:-}" ]]; then
    echo "usage: $0 [--json]" >&2
    exit 2
fi

log() {
    if [[ "$JSON_MODE" == "true" ]]; then
        printf '[KVM] %s\n' "$*" >&2
    else
        printf '[KVM] %s\n' "$*"
    fi
}

KVM_DEVICE="${KVM_DEVICE:-/dev/kvm}"
QEMU_BIN="${QEMU_BIN:-}"
if [[ -z "$QEMU_BIN" ]]; then
    QEMU_BIN="$(command -v qemu-system-x86_64 || true)"
fi
KVM_PROBE_TIMEOUT="${KVM_PROBE_TIMEOUT:-10}"
CHECKED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log "Checking ${KVM_DEVICE}"

# ---------------------------------------------------------------------------
# 1. Device existence, permissions, ownership
# ---------------------------------------------------------------------------
dev_exists=false
dev_readable=false
dev_writable=false
dev_permissions=""
dev_owner=""
dev_group=""

if [[ -e "$KVM_DEVICE" ]]; then
    dev_exists=true
    dev_permissions="$(stat -c '%A' "$KVM_DEVICE" 2>/dev/null || echo unknown)"
    dev_owner="$(stat -c '%U' "$KVM_DEVICE" 2>/dev/null || echo unknown)"
    dev_group="$(stat -c '%G' "$KVM_DEVICE" 2>/dev/null || echo unknown)"
    if [[ -r "$KVM_DEVICE" ]]; then dev_readable=true; fi
    if [[ -w "$KVM_DEVICE" ]]; then dev_writable=true; fi
    log "${KVM_DEVICE} exists: yes (${dev_permissions} ${dev_owner}:${dev_group}, readable=${dev_readable}, writable=${dev_writable})"
else
    log "${KVM_DEVICE} missing"
fi

# ---------------------------------------------------------------------------
# 2. CPU virtualization information
# ---------------------------------------------------------------------------
cpu_vmx=false
cpu_svm=false
cpu_hypervisor=false
cpu_model="unknown"

if [[ -r /proc/cpuinfo ]]; then
    if grep -qE '^flags[[:space:]]*:.*(^|[[:space:]])vmx([[:space:]]|$)' /proc/cpuinfo 2>/dev/null || \
       grep -qE 'vmx' /proc/cpuinfo 2>/dev/null; then
        cpu_vmx=true
    fi
    if grep -qE 'svm' /proc/cpuinfo 2>/dev/null; then
        cpu_svm=true
    fi
    if grep -qE ' hypervisor( |$)' /proc/cpuinfo 2>/dev/null; then
        cpu_hypervisor=true
    fi
    cpu_model="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ *//' || echo unknown)"
fi
if [[ "$cpu_vmx" == "true" || "$cpu_svm" == "true" ]]; then
    log "CPU virtualization flag: vmx=${cpu_vmx} svm=${cpu_svm} (${cpu_model})"
else
    log "CPU virtualization flag: none exposed (${cpu_model})"
fi
if [[ "$cpu_hypervisor" == "true" ]]; then
    log "Running inside a hypervisor (nested virtualization may be disabled by the host)"
fi

# ---------------------------------------------------------------------------
# 3. QEMU binary and accelerator support
# ---------------------------------------------------------------------------
qemu_present=false
qemu_version=""
qemu_accel_kvm_supported=false

if [[ -n "$QEMU_BIN" && -x "$QEMU_BIN" ]]; then
    qemu_present=true
    qemu_version="$("$QEMU_BIN" --version 2>/dev/null | head -n1 || true)"
    if "$QEMU_BIN" -accel help 2>/dev/null | grep -qw 'kvm'; then
        qemu_accel_kvm_supported=true
    fi
    log "QEMU: ${qemu_version:-unknown} (kvm accel advertised: ${qemu_accel_kvm_supported})"
else
    log "QEMU binary not found"
fi

# ---------------------------------------------------------------------------
# 4. Real QEMU + KVM probe
#
# QEMU is started in paused state (-S) with KVM acceleration. A working KVM
# setup starts and stays alive until `timeout` kills it (exit code 124). If
# KVM is missing or inaccessible QEMU exits immediately with an error.
# ---------------------------------------------------------------------------
qemu_probe="skipped"
qemu_probe_output=""

if [[ "$qemu_present" == "true" && "$qemu_accel_kvm_supported" == "true" && "$dev_exists" == "true" ]]; then
    set +e
    qemu_probe_output="$(timeout "$KVM_PROBE_TIMEOUT" "$QEMU_BIN" \
        -accel kvm \
        -cpu host \
        -machine q35 \
        -m 128 \
        -display none \
        -monitor none \
        -serial none \
        -nodefaults \
        -no-user-config \
        -S 2>&1)"
    probe_rc=$?
    set -e
    case "$probe_rc" in
        124)
            qemu_probe="ok"
            log "QEMU KVM probe: OK (VM started with KVM acceleration)"
            ;;
        0)
            qemu_probe="ok_exited"
            log "QEMU KVM probe: OK (QEMU initialized and exited cleanly)"
            ;;
        *)
            qemu_probe="failed"
            log "QEMU KVM probe: FAILED (exit ${probe_rc})"
            if [[ -n "$qemu_probe_output" ]]; then
                log "QEMU output: $(printf '%s' "$qemu_probe_output" | tr '\n' ' ' | cut -c1-500)"
            fi
            ;;
    esac
elif [[ "$dev_exists" != "true" ]]; then
    log "QEMU KVM probe: skipped (no KVM device)"
elif [[ "$qemu_accel_kvm_supported" != "true" ]]; then
    log "QEMU KVM probe: skipped (QEMU does not advertise the kvm accelerator)"
else
    log "QEMU KVM probe: skipped (QEMU unavailable)"
fi

# ---------------------------------------------------------------------------
# 5. Final determination
# ---------------------------------------------------------------------------
kvm_available=false
reason=""

if [[ "$dev_exists" != "true" ]]; then
    reason="${KVM_DEVICE} does not exist - the host does not expose KVM to this container"
elif [[ "$dev_readable" != "true" || "$dev_writable" != "true" ]]; then
    reason="${KVM_DEVICE} is not readable/writable by the current user"
elif [[ "$qemu_present" != "true" ]]; then
    reason="qemu-system-x86_64 is not installed"
elif [[ "$qemu_accel_kvm_supported" != "true" ]]; then
    reason="the installed QEMU does not support the kvm accelerator"
elif [[ "$qemu_probe" == "failed" ]]; then
    reason="QEMU could not start with -accel kvm (see probe output)"
else
    kvm_available=true
    reason="KVM is usable by QEMU"
fi

if [[ "$JSON_MODE" == "true" ]]; then
    export CHECKED_AT KVM_DEVICE QEMU_BIN KVM_PROBE_TIMEOUT
    export DEV_EXISTS="$dev_exists" DEV_READABLE="$dev_readable" DEV_WRITABLE="$dev_writable"
    export DEV_PERMISSIONS="$dev_permissions" DEV_OWNER="$dev_owner" DEV_GROUP="$dev_group"
    export CPU_VMX="$cpu_vmx" CPU_SVM="$cpu_svm" CPU_HYPERVISOR="$cpu_hypervisor" CPU_MODEL="$cpu_model"
    export QEMU_PRESENT="$qemu_present" QEMU_VERSION="$qemu_version"
    export QEMU_ACCEL_KVM="$qemu_accel_kvm_supported" QEMU_PROBE="$qemu_probe"
    export KVM_AVAILABLE="$kvm_available" REASON="$reason"
    python3 - <<'PY'
import json
import os

def b(name):
    return os.environ.get(name) == "true"

print(json.dumps({
    "checked_at": os.environ.get("CHECKED_AT"),
    "kvm_available": b("KVM_AVAILABLE"),
    "status": "KVM AVAILABLE" if b("KVM_AVAILABLE") else "KVM NOT AVAILABLE",
    "reason": os.environ.get("REASON"),
    "device": {
        "path": os.environ.get("KVM_DEVICE"),
        "exists": b("DEV_EXISTS"),
        "readable": b("DEV_READABLE"),
        "writable": b("DEV_WRITABLE"),
        "permissions": os.environ.get("DEV_PERMISSIONS"),
        "owner": os.environ.get("DEV_OWNER"),
        "group": os.environ.get("DEV_GROUP"),
    },
    "cpu": {
        "model": os.environ.get("CPU_MODEL"),
        "vmx": b("CPU_VMX"),
        "svm": b("CPU_SVM"),
        "hypervisor": b("CPU_HYPERVISOR"),
    },
    "qemu": {
        "binary": os.environ.get("QEMU_BIN"),
        "present": b("QEMU_PRESENT"),
        "version": os.environ.get("QEMU_VERSION"),
        "kvm_accel_supported": b("QEMU_ACCEL_KVM"),
        "kvm_probe": os.environ.get("QEMU_PROBE"),
    },
}, indent=2))
PY
fi

if [[ "$kvm_available" == "true" ]]; then
    log "AVAILABLE - ${reason}"
    exit 0
fi

log "NOT AVAILABLE - ${reason}"
exit 1
