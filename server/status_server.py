#!/usr/bin/env python3
# =============================================================================
# server/status_server.py
#
# Small local HTTP service that reports the state of the Render container,
# QEMU and the Windows VM. No external dependencies (Python stdlib only).
#
# Endpoints:
#   GET /health   always available, non-sensitive summary (used by health checks)
#   GET /status   detailed status; requires Bearer auth when STATUS_API_TOKEN is set
#   GET /         simple JSON index
#
# Security:
#   - never returns secrets (tokens, passwords, ngrok authtoken)
#   - /status is protected by STATUS_API_TOKEN unless STATUS_API_ALLOW_UNAUTH=true
# =============================================================================
from __future__ import annotations

import hmac
import json
import logging
import os
import shutil
import signal
import subprocess
import threading
import time
import urllib.request
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

APP_DIR = Path(__file__).resolve().parent.parent
SCRIPT_DIR = APP_DIR / "scripts"
STATE_DIR = Path(os.environ.get("VM_STATE_DIR", "/run/windows-vm"))
LOG_DIR = Path(os.environ.get("VM_LOG_DIR", "/var/log/windows-vm"))
DATA_DIR = Path(os.environ.get("VM_DATA_DIR", "/var/lib/windows"))
VM_DISK = Path(os.environ.get("VM_DISK", str(DATA_DIR / "windows10.qcow2")))

SERVER_START = time.time()
BIND_HOST = os.environ.get("STATUS_API_BIND", "0.0.0.0")
BIND_PORT = int(os.environ.get("PORT") or os.environ.get("STATUS_API_PORT") or "10000")
AUTH_TOKEN = os.environ.get("STATUS_API_TOKEN", "").strip()
ALLOW_UNAUTH = os.environ.get("STATUS_API_ALLOW_UNAUTH", "false").strip().lower() == "true"

KVM_REQUIRED = os.environ.get("KVM_REQUIRED", "true").strip().lower() == "true"
ENABLE_TCG_FALLBACK = os.environ.get("ENABLE_TCG_FALLBACK", "false").strip().lower() == "true"
KVM_TEST_ONLY = os.environ.get("KVM_TEST_ONLY", "false").strip().lower() == "true"
VM_AUTOSTART = os.environ.get("VM_AUTOSTART", "false").strip().lower() == "true"
NGROK_ENABLED = os.environ.get("NGROK_ENABLED", "false").strip().lower() == "true"

logging.basicConfig(
    level=logging.INFO,
    format="[STATUS] %(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%SZ",
)
log = logging.getLogger("status")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def read_json(path: Path) -> dict:
    try:
        with path.open(encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def run_cmd(args: list[str], timeout: float = 5.0) -> tuple[int, str]:
    try:
        proc = subprocess.run(
            args,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        return proc.returncode, (proc.stdout or proc.stderr or "").strip()
    except (OSError, subprocess.SubprocessError):
        return -1, ""


def service_uptime() -> int:
    started = STATE_DIR / "service-started-at"
    try:
        return max(0, int(time.time() - int(started.read_text(encoding="utf-8").strip())))
    except (OSError, ValueError):
        return int(time.time() - SERVER_START)


def service_started_at() -> str:
    started = STATE_DIR / "service-started-at.iso"
    try:
        value = started.read_text(encoding="utf-8").strip()
        return value or utc_now()
    except OSError:
        return utc_now()


def kvm_status() -> dict:
    cached = read_json(STATE_DIR / "kvm-status.json")
    if cached:
        return cached
    exists = os.path.exists("/dev/kvm")
    return {
        "checked_at": None,
        "kvm_available": exists,
        "status": "KVM AVAILABLE" if exists else "KVM NOT AVAILABLE",
        "reason": "cached status unavailable; /dev/kvm existence check only",
        "device": {"path": "/dev/kvm", "exists": exists},
    }


def vm_status() -> dict:
    rc, out = run_cmd([str(SCRIPT_DIR / "check-vm.sh"), "--json"], timeout=8)
    if rc in (0, 1):
        try:
            return json.loads(out)
        except ValueError:
            pass
    return {"running": False, "status": "unknown", "pid": None}


def disk_status() -> dict:
    info: dict = {
        "path": str(VM_DISK),
        "exists": VM_DISK.is_file(),
        "size_bytes": None,
        "virtual_size_bytes": None,
        "free_bytes": None,
        "total_bytes": None,
    }
    if VM_DISK.is_file():
        try:
            info["size_bytes"] = VM_DISK.stat().st_size
        except OSError:
            pass
        rc, out = run_cmd(["qemu-img", "info", "--output=json", str(VM_DISK)], timeout=8)
        if rc == 0:
            try:
                qemu_info = json.loads(out)
                info["virtual_size_bytes"] = qemu_info.get("virtual-size")
                info["actual_size_bytes"] = qemu_info.get("actual-size")
                info["format"] = qemu_info.get("format")
            except ValueError:
                pass
    try:
        usage = shutil.disk_usage(str(DATA_DIR))
        info["total_bytes"] = usage.total
        info["free_bytes"] = usage.free
        info["used_bytes"] = usage.used
    except OSError:
        pass
    return info


def ngrok_status() -> dict:
    result: dict = {
        "enabled": NGROK_ENABLED,
        "running": False,
        "pid": None,
        "tunnels": {},
        "started_at": None,
    }
    pid_file = STATE_DIR / "ngrok.pid"
    if pid_file.is_file():
        try:
            pid = int(pid_file.read_text(encoding="utf-8").strip())
            result["pid"] = pid
            result["running"] = Path(f"/proc/{pid}").exists()
        except (OSError, ValueError):
            pass
    urls = read_json(STATE_DIR / "ngrok-urls.json")
    if urls:
        result["tunnels"] = urls.get("tunnels", {})
        result["started_at"] = urls.get("started_at")
    # Live check through the local ngrok API (no secrets are returned).
    try:
        with urllib.request.urlopen("http://127.0.0.1:4040/api/tunnels", timeout=2) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
        live = {}
        for tunnel in payload.get("tunnels", []):
            name = tunnel.get("name")
            if name:
                live[name] = tunnel.get("public_url")
        if live:
            result["tunnels"] = live
            result["running"] = True
    except Exception:  # noqa: BLE001 - local API is optional
        pass
    return result


def build_status() -> dict:
    kvm = kvm_status()
    vm = vm_status()
    disk = disk_status()
    ngrok = ngrok_status()

    vm_state = "disabled"
    if not (KVM_TEST_ONLY or not VM_AUTOSTART):
        vm_state = "running" if vm.get("running") else "stopped"

    overall = "ok"
    if KVM_REQUIRED and not kvm.get("kvm_available", False) and not ENABLE_TCG_FALLBACK:
        overall = "degraded"
    if vm_state == "stopped" and not KVM_TEST_ONLY and VM_AUTOSTART:
        overall = "degraded"

    return {
        "service": {
            "status": overall,
            "name": "render-win10-qemu",
            "started_at": service_started_at(),
            "uptime_seconds": service_uptime(),
            "time": utc_now(),
        },
        "kvm": kvm,
        "qemu": {
            "acceleration": "tcg" if (not kvm.get("kvm_available") and ENABLE_TCG_FALLBACK) else ("kvm" if kvm.get("kvm_available") else "none"),
            "pid": vm.get("pid"),
            "running": bool(vm.get("running")),
        },
        "vm": {
            "name": os.environ.get("VM_NAME", "windows10"),
            "status": vm_state,
            "qemu_status": vm.get("qemu_status"),
            "autostart": VM_AUTOSTART,
            "kvm_test_only": KVM_TEST_ONLY,
        },
        "disk": disk,
        "config": {
            "memory_mb": int(os.environ.get("VM_MEMORY_MB", "0") or 0),
            "cpus": int(os.environ.get("VM_CPUS", "0") or 0),
            "machine": os.environ.get("VM_MACHINE", "q35"),
            "disk_bus": os.environ.get("VM_DISK_BUS", "virtio"),
            "disk_cache": os.environ.get("VM_DISK_CACHE", "writeback"),
            "boot_device": os.environ.get("VM_BOOT_DEVICE", "auto"),
            "kvm_required": KVM_REQUIRED,
            "tcg_fallback_enabled": ENABLE_TCG_FALLBACK,
        },
        "ngrok": ngrok,
        "security": {
            "rdp_exposed_publicly": False,
            "rdp_tunneled": bool(ngrok.get("tunnels", {}).get("rdp")),
            "status_api_auth_required": bool(AUTH_TOKEN) or not ALLOW_UNAUTH,
        },
    }


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    server_version = "render-win10-status/1.0"

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        client = self.client_address[0] if self.client_address else "-"
        log.info("%s %s", client, fmt % args)

    def _send_json(self, payload: dict, code: int = HTTPStatus.OK) -> None:
        body = json.dumps(payload, indent=2).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self) -> bool:
        if not AUTH_TOKEN:
            return ALLOW_UNAUTH
        header = self.headers.get("Authorization", "")
        if not header.startswith("Bearer "):
            return False
        supplied = header[len("Bearer "):].strip()
        return hmac.compare_digest(supplied, AUTH_TOKEN)

    def _require_auth(self) -> bool:
        if self._authorized():
            return True
        self.send_response(HTTPStatus.UNAUTHORIZED)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("WWW-Authenticate", 'Bearer realm="win10-status"')
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(json.dumps({
            "error": "unauthorized",
            "hint": "set the Authorization: Bearer <STATUS_API_TOKEN> header",
        }).encode("utf-8"))
        return False

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0].rstrip("/") or "/"

        if path in ("/", "/index"):
            self._send_json({
                "service": "render-win10-qemu",
                "endpoints": ["/health", "/status"],
                "note": "/status requires bearer authentication when configured",
            })
            return

        if path == "/health":
            status = build_status()
            health_status = "ok" if status["service"]["status"] == "ok" else "degraded"
            self._send_json({
                "status": health_status,
                "kvm": "available" if status["kvm"].get("kvm_available") else "unavailable",
                "acceleration": status["qemu"]["acceleration"],
                "vm": status["vm"]["status"],
                "uptime_seconds": status["service"]["uptime_seconds"],
            })
            return

        if path == "/status":
            if not self._require_auth():
                return
            self._send_json(build_status())
            return

        self._send_json({"error": "not found"}, code=HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:  # noqa: N802
        self._send_json({"error": "method not allowed"}, code=HTTPStatus.METHOD_NOT_ALLOWED)

    do_PUT = do_POST
    do_DELETE = do_POST
    do_PATCH = do_POST


def main() -> None:
    log.info("starting status server on %s:%s", BIND_HOST, BIND_PORT)
    if not AUTH_TOKEN and not ALLOW_UNAUTH:
        log.warning("/status requires STATUS_API_TOKEN or STATUS_API_ALLOW_UNAUTH=true")
    server = ThreadingHTTPServer((BIND_HOST, BIND_PORT), Handler)
    server.daemon_threads = True

    def handle_signal(signum, _frame):
        log.info("received signal %s - shutting down", signum)
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    try:
        server.serve_forever(poll_interval=1.0)
    finally:
        server.server_close()
        log.info("status server stopped")


if __name__ == "__main__":
    main()
