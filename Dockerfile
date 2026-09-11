# =============================================================================
# Windows 10 VM on Render - Docker runtime
#
# Contains: QEMU (KVM capable), QEMU utilities, OVMF/UEFI firmware, ngrok,
# Python 3 (status server), tini (init / signal handling).
#
# The image is distributed *without* any Windows installation media. The
# administrator must provide a legally obtained Windows 10 ISO at runtime.
# =============================================================================
FROM debian:bookworm-slim

LABEL org.opencontainers.image.title="render-win10-qemu" \
      org.opencontainers.image.description="Windows 10 VM (QEMU/KVM) with ngrok RDP tunnel and status API" \
      org.opencontainers.image.source="https://github.com/dynamite-ai-coder/win10" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PYTHONUNBUFFERED=1 \
    VM_DATA_DIR=/var/lib/windows \
    VM_STATE_DIR=/run/windows-vm \
    VM_LOG_DIR=/var/log/windows-vm

# --- System packages --------------------------------------------------------
# qemu-system-x86 : full x86_64 system emulator (KVM + TCG + utilities)
# qemu-utils      : qemu-img (QCOW2 management, snapshots, info)
# ovmf            : UEFI firmware (OVMF_CODE / OVMF_VARS)
# socat           : QEMU monitor (unix socket) communication for graceful stop
# tini            : PID 1 init, forwards signals and reaps zombies
# python3         : stdlib-only status server
# curl/wget/jq    : diagnostics, ISO downloads, ngrok API parsing
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        coreutils \
        curl \
        iproute2 \
        jq \
        net-tools \
        ovmf \
        procps \
        python3 \
        qemu-system-x86 \
        qemu-utils \
        socat \
        tini \
        unzip \
        util-linux \
        wget; \
    rm -rf /var/lib/apt/lists/*

# --- ngrok (official stable static build) -----------------------------------
# Uses the officially documented ngrok v3 static download. Pinned to the
# "stable" channel; the docker build fails fast if the download is broken.
ARG TARGETARCH=amd64
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) NGROK_ARCH=amd64 ;; \
        arm64) NGROK_ARCH=arm64 ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/ngrok.tgz \
        "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-${NGROK_ARCH}.tgz"; \
    tar -xzf /tmp/ngrok.tgz -C /usr/local/bin ngrok; \
    chmod 0755 /usr/local/bin/ngrok; \
    rm -f /tmp/ngrok.tgz; \
    /usr/local/bin/ngrok version

# --- Application layout -----------------------------------------------------
WORKDIR /app

COPY scripts/ /app/scripts/
COPY server/ /app/server/
COPY tests/ /app/tests/
COPY config/ /app/config/

RUN set -eux; \
    chmod 0755 /app/scripts/*.sh; \
    mkdir -p /var/lib/windows /run/windows-vm /var/log/windows-vm; \
    ln -sf /app/scripts/entrypoint.sh /usr/local/bin/win10-entrypoint; \
    ln -sf /app/scripts/check-kvm.sh /usr/local/bin/check-kvm; \
    ln -sf /app/scripts/check-vm.sh /usr/local/bin/check-vm; \
    ln -sf /app/scripts/start-vm.sh /usr/local/bin/start-vm; \
    ln -sf /app/scripts/stop-vm.sh /usr/local/bin/stop-vm

# Status API / management endpoint
EXPOSE 10000

# Local convenience healthcheck (Render uses its own health checks for web
# services; private services are checked by the platform routing layer).
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${PORT:-10000}/health" >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/app/scripts/entrypoint.sh"]
