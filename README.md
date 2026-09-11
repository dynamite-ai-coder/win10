# Windows 10 VM on Render (QEMU/KVM + ngrok + Selenium)

Run a real Windows 10 desktop on Render inside a Docker service, access it
securely over an ngrok TCP tunnel (RDP), and automate Chrome with Selenium
inside the Windows GUI session.

> **Reality check first.** Render does not document `/dev/kvm` passthrough.
> This project therefore starts in **diagnostics-only mode** and refuses to
> boot Windows unless KVM is actually usable (unless you explicitly opt into
> slow TCG software emulation). The first deployment goal is:
>
> `Render container -> /dev/kvm -> QEMU -> KVM acceleration`
>
> Only after that is confirmed should you install Windows.

---

## Architecture

```
                          Internet
                             |
                       [ ngrok cloud ]   (only the tunnels you enable)
                             |
        +--------------------+---------------------+
        |                                          |
  TCP tunnel (RDP)                        HTTPS tunnel (optional)
        |                                          |
========|==========================================|========================
        |              Render Docker container    |         (private service)
        |   +-----------------------------------------+
        |   |  tini (PID 1)                           |
        |   |   +--> scripts/entrypoint.sh            |
        |   |         +--> check-kvm.sh               |  /dev/kvm (if present)
        |   |         +--> setup-disk.sh              |  /var/lib/windows (disk)
        |   |         +--> start-vm.sh ---+           |
        |   |         +--> start-ngrok.sh |           |
        |   |         +--> status_server.py :10000    |
        |   +----------------------------|------------+
        |                                |
        |                        QEMU process (qemu-system-x86_64)
        |                        -accel kvm | tcg, Q35, OVMF UEFI
        |                        VirtIO disk/NIC, hostfwd 127.0.0.1:3389
        |                                |
        |                     +----------v-----------+
        |                     |   Windows 10 VM      |
        |                     |  - desktop/GUI       |
        |                     |  - RDP :3389         |
        |                     |  - Chrome (GUI)      |
        |                     |  - ChromeDriver      |
        |                     |  - Python + Selenium |
        |                     +----------------------+
        +---------------------------------------------------------------

Layer map (do not confuse these):
  1. Render container/host  -> Linux, Docker, QEMU binaries, scripts
  2. QEMU process           -> emulator/virtualizer, PID tracked in /run/windows-vm
  3. Windows 10 VM          -> guest OS, persistent on /var/lib/windows/windows10.qcow2
  4. ngrok tunnel           -> secure public endpoint for RDP and/or the status API
  5. RDP                    -> Windows Remote Desktop protocol inside the VM
  6. Chrome/Selenium        -> applications running INSIDE Windows (not Linux)
```

There is no Linux desktop, no Wine and no XFCE. The only GUI is Windows 10,
consumed over RDP.

---

## Project layout

```
/
├── Dockerfile
├── render.yaml                 # Render Blueprint (single-instance private service)
├── README.md
├── RENDER.md                   # step-by-step Render deployment
├── .env.example                # every supported environment variable
├── .gitignore
├── .dockerignore
├── scripts/
│   ├── entrypoint.sh           # supervisor / startup sequence
│   ├── check-kvm.sh            # KVM capability test (JSON or human)
│   ├── start-vm.sh             # QEMU command construction + launch
│   ├── stop-vm.sh              # ACPI shutdown -> quit -> SIGTERM -> SIGKILL
│   ├── check-vm.sh             # VM/QEMU status (JSON or human)
│   ├── setup-disk.sh           # persistent disk / QCOW2 / OVMF / ISOs
│   └── start-ngrok.sh          # secure RDP + status API tunnels
├── server/
│   └── status_server.py        # GET /health, GET /status (stdlib only)
├── tests/
│   ├── selenium_test.py        # runs inside Windows (GUI, not headless)
│   └── selenium_test.ps1       # PowerShell alternative
├── docs/
│   └── WINDOWS_SETUP.md        # Windows installation + RDP + Chrome + Selenium
└── config/
    └── qemu.conf.example       # environment reference / QEMU mapping
```

---

## Prerequisites

- A GitHub account with this repository.
- A Render account with a paid workspace (persistent disks and the
  `8c-32g` compute plan are paid features).
- A legally obtained Windows 10 installation ISO (not included).
- virtio-win driver ISO (recommended; Fedora project).
- An ngrok account with an authtoken (secret).
- An RDP client: Microsoft Remote Desktop (Windows/macOS), Remmina (Linux) or
  an Android RDP client.

---

## Render requirements

| Setting          | Value                                                |
| ---------------- | ---------------------------------------------------- |
| Service type     | Private Service (`pserv`)                            |
| Runtime          | Docker                                               |
| Instances        | **1** (must never be scaled - persistent disk + VM)  |
| Compute plan     | `8c-32g` (8 CPU / 32 GB) recommended                 |
| Region           | your choice at creation (example: `frankfurt`)       |
| Persistent disk  | 150 GB SSD mounted at `/var/lib/windows`             |
| Port             | `10000` (status API)                                 |
| Secrets          | `NGROK_AUTHTOKEN`, `STATUS_API_TOKEN`                |

`render.yaml` encodes all of this. See [RENDER.md](RENDER.md) for exact
Dashboard settings and the API procedure.

---

## Deployment procedure (summary)

Full details: [RENDER.md](RENDER.md).

1. Push this repository to GitHub.
2. Create the Render service (Docker, private service, single instance,
   `8c-32g`) and attach a 150 GB disk at `/var/lib/windows`.
3. Add environment variables (`NGROK_ENABLED=false` is fine initially) and the
   `NGROK_AUTHTOKEN` secret.
4. Deploy and watch the logs.
5. Run the KVM check (below). **Continue only if KVM is available.**
6. Provide the Windows ISO and install Windows (see
   [docs/WINDOWS_SETUP.md](docs/WINDOWS_SETUP.md)).
7. Enable the ngrok tunnel and connect over RDP.
8. Set `VM_AUTOSTART=true`, `KVM_TEST_ONLY=false` for future restarts.

### Exact commands (local, with the Render CLI or plain `git`)

```bash
git clone https://github.com/dynamite-ai-coder/win10.git
cd win10
git add -A && git commit -m "Windows 10 VM service" && git push origin main
```

Render API alternative (create a service programmatically) is documented in
[RENDER.md](RENDER.md#configure-the-service-via-the-render-api).

---

## KVM verification (do this first)

### In the Render Shell

```bash
check-kvm          # human readable, exits 0 only when KVM is usable
check-kvm --json   # machine readable
```

Expected success:

```
[KVM] Checking /dev/kvm
[KVM] /dev/kvm exists: yes (crw-rw---- root:kvm, readable=true, writable=true)
[KVM] QEMU KVM probe: OK (VM started with KVM acceleration)
[KVM] AVAILABLE - KVM is usable by QEMU
```

Failure (expected on current Render hosts unless KVM is exposed):

```
[KVM] /dev/kvm missing
[KVM] NOT AVAILABLE - /dev/kvm does not exist - the host does not expose KVM to this container
```

### Through the status API

```bash
curl -s http://127.0.0.1:10000/health
curl -s -H "Authorization: Bearer $STATUS_API_TOKEN" http://127.0.0.1:10000/status
```

The same result is printed in the container logs at startup and stored in
`/run/windows-vm/kvm-status.json`.

### Diagnostics-only container mode

Set `KVM_TEST_ONLY=true` (default in `render.yaml` during bring-up) to run all
KVM diagnostics, keep the status API available and never boot Windows.

---

## Persistent disk configuration

| Item                | Path                                          |
| ------------------- | --------------------------------------------- |
| Mount path          | `/var/lib/windows`                            |
| System disk         | `/var/lib/windows/windows10.qcow2`            |
| UEFI variable store | `/var/lib/windows/uefi/OVMF_VARS.fd`          |
| Installation media  | `/var/lib/windows/iso/*.iso`                  |
| Metadata / state    | `/var/lib/windows/state/`                     |
| Snapshots           | `/var/lib/windows/snapshots/`                 |

The entrypoint refuses to start if `VM_DISK` or `OVMF_VARS` point outside
`VM_DATA_DIR`, guaranteeing Windows never lives on the ephemeral container
filesystem. The disk is attached to exactly one instance, so the service must
remain single-instance.

---

## Windows installation procedure

See [docs/WINDOWS_SETUP.md](docs/WINDOWS_SETUP.md). Short version:

1. Put `windows10.iso` and `virtio-win.iso` under `/var/lib/windows/iso/`.
2. Start the VM (`start-vm`).
3. Install Windows, loading the VirtIO storage driver from the virtio CD.
4. Create the marker `/var/lib/windows/state/windows_installed`.
5. Install Chrome, Python and Selenium; enable Remote Desktop.

---

## ngrok and remote access

ngrok is **disabled by default** (`NGROK_ENABLED=false`). To enable:

1. Add `NGROK_AUTHTOKEN` as a Render secret.
2. Set `NGROK_ENABLED=true`.
3. Choose tunnels via `NGROK_TUNNELS`:
   - `rdp` (default) - TCP tunnel to `127.0.0.1:3389`, secure remote desktop
   - `api` - HTTPS tunnel to the status API (`/health`, authenticated `/status`)
   - `rdp,api` for both

**Tunneled ports (exact):**

| Tunnel | Local target             | Public protocol | Purpose            |
| ------ | ------------------------ | --------------- | ------------------ |
| `rdp`  | `127.0.0.1:3389` (guest) | `tcp://host:port` | Windows RDP      |
| `api`  | `127.0.0.1:10000`        | `https://...`     | status/health API |

Nothing else is tunneled, and `3389` is never published directly by Render.
The entrypoint prints the live endpoints, which are also available at
`GET /status` and in `/run/windows-vm/ngrok-urls.json`.

> ngrok free workspaces may limit concurrent endpoints; use `NGROK_TUNNELS=rdp`
> first and add `api` only if your plan permits.

---

## RDP connection procedure

The connection string is `host:port` printed by ngrok (for example
`0.tcp.ngrok.io:12345`).

### From Windows

1. Open **Remote Desktop Connection** (`mstsc`).
2. Computer: `0.tcp.ngrok.io:12345` (your ngrok endpoint).
3. User name: the Windows account created during installation.
4. Connect and accept the certificate prompt.

### From Android

1. Install **Microsoft Remote Desktop** (or RD Client) from Google Play.
2. Add PC → Host name: ngrok host, Port: ngrok port.
3. Enter the Windows account name and password, then connect.

Use a strong password. RDP credentials are never stored in this repository.

---

## Selenium setup

Everything here runs **inside Windows**, not in the Linux container:

- Chrome (normal GUI, **not** headless)
- matching ChromeDriver (Selenium Manager automatic)
- Python + Selenium
- `tests/selenium_test.py`

See [docs/WINDOWS_SETUP.md](docs/WINDOWS_SETUP.md#5-chromedriver--selenium).

---

## Health and status API

| Endpoint  | Auth                                   | Contents |
| --------- | -------------------------------------- | -------- |
| `/health` | none (non-sensitive summary)           | overall status, KVM availability, acceleration, VM status, uptime |
| `/status` | `Authorization: Bearer $STATUS_API_TOKEN` | full report: service, KVM, QEMU, VM, disk, config, ngrok, uptime |

`/status` is never exposed unauthenticated: when `STATUS_API_TOKEN` is unset it
returns `401` unless `STATUS_API_ALLOW_UNAUTH=true` is explicitly set. Secrets
are never included in any response.

---

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `[KVM] NOT AVAILABLE` and service keeps running without a VM | Expected on hosts without `/dev/kvm`. Confirm with `check-kvm`. Render does not document KVM passthrough. Do not "fix" this by pretending TCG is KVM. |
| `[ERROR] KVM is required but /dev/kvm is unavailable` then exit | `VM_AUTOSTART=true` while KVM is missing. Set `KVM_REQUIRED=false` + `ENABLE_TCG_FALLBACK=true` to explicitly accept slow emulation, or leave `VM_AUTOSTART=false`. |
| QEMU exits immediately, log shows `Could not access KVM kernel module` | `/dev/kvm` missing or not accessible. Same as above. |
| Windows installer shows no disk | Load the VirtIO driver from the virtio CD (`viostor\w10\amd64`) or set `VM_DISK_BUS=sata`. |
| Windows reboots into the installer repeatedly | The install marker is missing. Create `/var/lib/windows/state/windows_installed`. |
| RDP connection refused | `fDenyTSConnections` must be `0`, TermService running, firewall rule enabled. Verify `NGROK_TUNNELS` contains `rdp` and the ngrok PID is alive. |
| ngrok did not start | `NGROK_AUTHTOKEN` missing or invalid. Check `NGROK_ENABLED=true` and the `[NGROK]` logs. |
| `[VM] ... TCG` in status | `ENABLE_TCG_FALLBACK=true` was set. Performance will be extremely slow; this is intentional and clearly reported. |
| Disk full | `disk.free_bytes` through `/status`; increase the Render persistent disk size in the Dashboard. |
| Service restarts lose Windows state | The disk is not mounted at `/var/lib/windows`. Check the Render Disks tab and the `[DISK]` logs. |

---

## Security

- No hard-coded credentials, tokens or ISO images.
- RDP is bound to `127.0.0.1` inside the container and exposed only via ngrok.
- QEMU monitor/QMP listen on unix sockets, never TCP.
- `/status` requires a bearer token; `/health` contains no secrets.
- Secrets (`NGROK_AUTHTOKEN`, `STATUS_API_TOKEN`) are supplied through Render
  environment variables and are never written to the persistent disk.
- Use a strong Windows administrator password and keep Windows updated.
