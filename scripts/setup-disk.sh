#!/usr/bin/env bash
# =============================================================================
# scripts/setup-disk.sh
#
# Prepares the persistent storage below /var/lib/windows:
#   - validates the mount exists and is writable
#   - creates the QCOW2 disk when explicitly enabled
#   - copies the OVMF UEFI variable store into persistent storage
#   - optionally downloads administrator-supplied installation media
#   - records metadata (installation state) for future boots
#
# This script never downloads Windows without an explicit URL and it never
# bundles or redistributes Microsoft installation media.
# =============================================================================
set -Eeuo pipefail

VM_DATA_DIR="${VM_DATA_DIR:-/var/lib/windows}"
VM_DISK="${VM_DISK:-${VM_DATA_DIR}/windows10.qcow2}"
VM_DISK_SIZE_GB="${VM_DISK_SIZE_GB:-120}"
VM_DISK_AUTOCREATE="${VM_DISK_AUTOCREATE:-false}"
WINDOWS_ISO="${WINDOWS_ISO:-${VM_DATA_DIR}/iso/windows10.iso}"
WINDOWS_ISO_URL="${WINDOWS_ISO_URL:-}"
VIRTIO_ISO="${VIRTIO_ISO:-${VM_DATA_DIR}/iso/virtio-win.iso}"
VIRTIO_ISO_URL="${VIRTIO_ISO_URL:-}"
OVMF_VARS="${OVMF_VARS:-${VM_DATA_DIR}/uefi/OVMF_VARS.fd}"
OVMF_VARS_TEMPLATE="${OVMF_VARS_TEMPLATE:-/usr/share/OVMF/OVMF_VARS_4M.fd}"
VM_INSTALL_MARKER="${VM_INSTALL_MARKER:-${VM_DATA_DIR}/state/windows_installed}"
ISO_DOWNLOAD_TIMEOUT="${ISO_DOWNLOAD_TIMEOUT:-1800}"

log()  { printf '[DISK] %s\n' "$*"; }
warn() { printf '[DISK][WARN] %s\n' "$*" >&2; }
err()  { printf '[DISK][ERROR] %s\n' "$*" >&2; }

is_true() {
    case "${1,,}" in
        true|1|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# 1. Validate the persistent disk mount
# ---------------------------------------------------------------------------
if [[ ! -d "$VM_DATA_DIR" ]]; then
    err "persistent directory ${VM_DATA_DIR} does not exist"
    err "mount a Render persistent disk at ${VM_DATA_DIR}"
    exit 1
fi

if ! touch "${VM_DATA_DIR}/.write-test" 2>/dev/null; then
    err "${VM_DATA_DIR} is not writable - check the Render persistent disk mount"
    err "the VM disk MUST NOT live on the ephemeral container filesystem"
    exit 1
fi
rm -f "${VM_DATA_DIR}/.write-test"
log "persistent storage ${VM_DATA_DIR} is writable"

mkdir -p "${VM_DATA_DIR}/iso" \
         "${VM_DATA_DIR}/uefi" \
         "${VM_DATA_DIR}/state" \
         "${VM_DATA_DIR}/snapshots"

# ---------------------------------------------------------------------------
# 2. QCOW2 system disk
# ---------------------------------------------------------------------------
disk_created=false
disk_present=false
if [[ -f "$VM_DISK" ]]; then
    disk_present=true
    log "disk exists: ${VM_DISK}"
elif is_true "$VM_DISK_AUTOCREATE"; then
    log "creating QCOW2 disk ${VM_DISK} (${VM_DISK_SIZE_GB}G virtual, qcow2 sparse)"
    if ! qemu-img create -f qcow2 "$VM_DISK" "${VM_DISK_SIZE_GB}G"; then
        err "failed to create ${VM_DISK}"
        exit 1
    fi
    disk_created=true
    disk_present=true
else
    # Keep the container (and the status API) alive in KVM-test / diagnostics
    # mode. start-vm.sh refuses to start the VM without a disk, so this warning
    # can never result in a QEMU launch with a missing system disk.
    warn "disk ${VM_DISK} does not exist and VM_DISK_AUTOCREATE=false"
    warn "the VM will not start until a disk exists (set VM_DISK_AUTOCREATE=true or create it)"
fi

if [[ "$disk_present" == "true" ]]; then
    if ! qemu-img info "$VM_DISK" >/dev/null 2>&1; then
        err "${VM_DISK} is not a valid QEMU disk image"
        exit 1
    fi
    log "disk info: $(qemu-img info --output=json "$VM_DISK" 2>/dev/null | jq -c '{virtual_size:.virtual_size,actual_size:.actual_size,format:.format}' 2>/dev/null || echo 'ok')"
fi

# ---------------------------------------------------------------------------
# 3. UEFI variable store (persistent, per-VM)
# ---------------------------------------------------------------------------
if [[ ! -f "$OVMF_VARS" ]]; then
    if [[ ! -f "$OVMF_VARS_TEMPLATE" ]]; then
        err "OVMF variable template ${OVMF_VARS_TEMPLATE} not found"
        err "install the 'ovmf' package or set OVMF_VARS_TEMPLATE"
        exit 1
    fi
    cp -f "$OVMF_VARS_TEMPLATE" "$OVMF_VARS"
    log "created persistent UEFI variable store ${OVMF_VARS}"
else
    log "UEFI variable store exists: ${OVMF_VARS}"
fi

# ---------------------------------------------------------------------------
# 4. Installation media (optional, administrator supplied)
# ---------------------------------------------------------------------------
download_if_missing() {
    local target="$1" url="$2" label="$3"
    if [[ -f "$target" ]]; then
        log "${label} present: ${target}"
        return 0
    fi
    if [[ -z "$url" ]]; then
        warn "${label} missing and no URL configured (${target})"
        return 1
    fi
    log "downloading ${label} from configured URL (this can take a while)"
    mkdir -p "$(dirname "$target")"
    if ! curl -fL --retry 3 --retry-delay 5 --connect-timeout 30 \
              --max-time "$ISO_DOWNLOAD_TIMEOUT" \
              -o "${target}.part" "$url"; then
        err "download of ${label} failed"
        rm -f "${target}.part"
        return 1
    fi
    mv -f "${target}.part" "$target"
    log "${label} downloaded: ${target}"
    return 0
}

download_if_missing "$WINDOWS_ISO" "$WINDOWS_ISO_URL" "Windows 10 ISO" || true
download_if_missing "$VIRTIO_ISO" "$VIRTIO_ISO_URL" "VirtIO driver ISO" || true

if [[ ! -f "$WINDOWS_ISO" ]]; then
    warn "Windows 10 installation media is not present."
    warn "The VM cannot be installed until an ISO is supplied."
    warn "See docs/WINDOWS_SETUP.md - do NOT use pirated images."
fi

# ---------------------------------------------------------------------------
# 5. Persist metadata / installation state
# ---------------------------------------------------------------------------
{
    printf '{\n'
    printf '  "updated_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "disk": "%s",\n' "$VM_DISK"
    printf '  "disk_created_now": %s,\n' "$disk_created"
    printf '  "windows_iso_present": %s,\n' "$([[ -f "$WINDOWS_ISO" ]] && echo true || echo false)"
    printf '  "virtio_iso_present": %s,\n' "$([[ -f "$VIRTIO_ISO" ]] && echo true || echo false)"
    printf '  "windows_installed": %s\n' "$([[ -f "$VM_INSTALL_MARKER" ]] && echo true || echo false)"
    printf '}\n'
} > "${VM_DATA_DIR}/state/storage.json"

log "storage ready (Windows installed marker: $([[ -f "$VM_INSTALL_MARKER" ]] && echo yes || echo no))"
