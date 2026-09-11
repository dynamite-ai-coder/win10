# Render Deployment Guide

This is the exact procedure for deploying the Windows 10 VM service on Render.
It documents both the Dashboard workflow and the Render API workflow.

---

## 0. Recommended hardware (initial)

| Setting             | Value                                             |
| ------------------- | ------------------------------------------------- |
| Service type        | **Private Service** (`pserv`)                     |
| Runtime             | **Docker**                                        |
| Compute plan        | **8c-32g** (8 CPU / 32 GB RAM)                    |
| Instances           | **1** (single instance - required)                |
| Persistent disk     | **150 GB SSD**                                    |
| Disk mount path     | **`/var/lib/windows`**                            |
| Port                | **10000** (status API)                            |
| Region              | your choice, e.g. `frankfurt` (immutable later)   |
| Auto-deploy         | on commit to `main` (optional)                    |

VM allocation on top of the container: 6-8 vCPU, 20-24 GB RAM. The remaining
resources are for Docker, QEMU overhead, ngrok, the status server and the OS.

> Render compute plan IDs are documented (see
> <https://render.com/docs/blueprint-spec>). `8c-32g` is the plan matching the
> project's recommended 8 CPU / 32 GB, and it exists for private services.
> `8c-16g` also works if you reduce `VM_MEMORY_MB` (e.g. `12288`).

---

## 1. Dashboard procedure

1. **Create a new service**: Dashboard → **New +** → **Private Service**.
   (A private service is preferred for the VM; it has no public URL.)
2. **Select Docker** as the runtime/environment.
3. **Connect the GitHub repository** `dynamite-ai-coder/win10`
   (branch `main`).
4. **Select the compute plan `8c-32g`** initially.
   For an existing service: *Settings → Instance Type → 8c-32g*.
5. **Add a persistent disk**:
   - *Advanced* (during creation) or *Disks* tab (after creation)
   - Size: **150 GB**
   - Mount path: **`/var/lib/windows`**
   - Name: `win10-data`
6. **Add environment variables** from the table below
   (*Environment* tab). Keep `KVM_TEST_ONLY=true` and `VM_AUTOSTART=false`
   for the first deploy.
7. **Add the ngrok secret**: `NGROK_AUTHTOKEN` (mark as secret). You can leave
   `NGROK_ENABLED=false` until Windows is installed.
8. **Deploy** (*Manual Deploy → Deploy latest commit* or save the settings).
9. **Examine the logs**: look for `[BOOT]`, `[KVM]`, `[DISK]`, `[QEMU]`,
   `[NGROK]`, `[VM]` lines.
10. **Run the KVM capability test**:
    - Shell: `check-kvm` (or `check-kvm --json`)
    - Local HTTP: `curl -s http://127.0.0.1:10000/health`
11. **Continue only if KVM is available.** If it is not, read the failure
    behavior section below before doing anything else.
12. Only then: provide the Windows ISO and set `KVM_TEST_ONLY=false`,
    `VM_AUTOSTART=true` (see [WINDOWS_SETUP.md](docs/WINDOWS_SETUP.md)).

### Environment variables

| Variable | Value | Notes |
| --- | --- | --- |
| `PORT` | `10000` | status API |
| `STATUS_API_TOKEN` | *(secret, generated)* | protects `GET /status` |
| `STATUS_API_ALLOW_UNAUTH` | `false` | never unauthenticated |
| `KVM_REQUIRED` | `true` | refuse to boot without KVM |
| `ENABLE_TCG_FALLBACK` | `false` | explicit opt-in only |
| `KVM_TEST_ONLY` | `true` initially | diagnostics only at first |
| `VM_AUTOSTART` | `false` initially | prove KVM first |
| `VM_MEMORY_MB` | `22528` (22 GB) | 8c-32g headroom |
| `VM_CPUS` | `6` | 6 of 8 host CPUs |
| `VM_DISK` | `/var/lib/windows/windows10.qcow2` | persistent |
| `VM_DISK_SIZE_GB` | `120` | within 150 GB disk |
| `VM_DISK_AUTOCREATE` | `true` | create QCOW2 on first boot |
| `VM_DISK_BUS` | `virtio` | set `sata` to avoid VirtIO drivers |
| `WINDOWS_ISO` | `/var/lib/windows/iso/windows10.iso` | admin supplied |
| `WINDOWS_ISO_URL` | *(optional)* | admin supplied download URL |
| `NGROK_ENABLED` | `false` → `true` | after adding the token |
| `NGROK_REQUIRED` | `false` | set `true` to fail hard without a tunnel |
| `NGROK_AUTHTOKEN` | *(secret)* | never in `render.yaml` |
| `NGROK_TUNNELS` | `rdp` or `rdp,api` | only these ports are tunneled |
| `DEBUG_MODE` | `false` | `true` for full diagnostics (no secrets) |

---

## 2. Configure the service via the Render API

Replace `rnd_...` with your API key. All examples use `curl`.

### 2.1 List services and find the service ID

```bash
curl -s -H "Authorization: Bearer $RENDER_API_KEY" \
  "https://api.render.com/v1/services?limit=50"
```

### 2.2 Create the service (if it does not exist)

```bash
curl -s -X POST "https://api.render.com/v1/services" \
  -H "Authorization: Bearer $RENDER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "private_service",
    "name": "win10",
    "ownerId": "YOUR_OWNER_ID",
    "repo": "https://github.com/dynamite-ai-coder/win10",
    "branch": "main",
    "autoDeploy": "yes",
    "serviceDetails": {
      "env": "docker",
      "region": "frankfurt",
      "plan": "8c-32g",
      "numInstances": 1,
      "envSpecificDetails": {
        "dockerfilePath": "./Dockerfile",
        "dockerContext": "."
      },
      "disk": {
        "name": "win10-data",
        "mountPath": "/var/lib/windows",
        "sizeGB": 150
      },
      "envVars": [
        { "key": "KVM_REQUIRED", "value": "true" },
        { "key": "ENABLE_TCG_FALLBACK", "value": "false" },
        { "key": "KVM_TEST_ONLY", "value": "true" },
        { "key": "VM_AUTOSTART", "value": "false" }
      ]
    }
  }'
```

### 2.3 Update an existing service (plan, Docker settings)

```bash
curl -s -X PATCH "https://api.render.com/v1/services/SERVICE_ID" \
  -H "Authorization: Bearer $RENDER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "serviceDetails": {
      "plan": "8c-32g",
      "numInstances": 1,
      "envSpecificDetails": {
        "dockerfilePath": "./Dockerfile",
        "dockerContext": "."
      }
    }
  }'
```

### 2.4 Attach the 150 GB persistent disk

```bash
curl -s -X POST "https://api.render.com/v1/disks" \
  -H "Authorization: Bearer $RENDER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "win10-data",
    "serviceId": "SERVICE_ID",
    "mountPath": "/var/lib/windows",
    "sizeGB": 150
  }'
```

### 2.5 Set environment variables (including secrets)

`PUT /v1/services/{id}/env-vars` replaces the full variable set.

```bash
curl -s -X PUT "https://api.render.com/v1/services/SERVICE_ID/env-vars" \
  -H "Authorization: Bearer $RENDER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '[
    { "key": "VM_MEMORY_MB", "value": "22528" },
    { "key": "VM_CPUS", "value": "6" },
    { "key": "KVM_REQUIRED", "value": "true" },
    { "key": "NGROK_AUTHTOKEN", "value": "YOUR_NGROK_TOKEN" }
  ]'
```

### 2.6 Deploy and follow the logs

```bash
# trigger a deploy
curl -s -X POST "https://api.render.com/v1/services/SERVICE_ID/deploys" \
  -H "Authorization: Bearer $RENDER_API_KEY" \
  -H "Content-Type: application/json" -d '{"clearCache": "do_not_clear"}'

# recent logs
curl -s -H "Authorization: Bearer $RENDER_API_KEY" \
  "https://api.render.com/v1/logs?ownerId=OWNER_ID&resourceId=SERVICE_ID&limit=100"
```

---

## 3. KVM verification (mandatory before Windows)

Run in the Render Shell:

```bash
check-kvm
```

- `KVM AVAILABLE` → proceed to install Windows.
- `KVM NOT AVAILABLE` → **stop**. Do not set `VM_AUTOSTART=true`. Read the
  section below.

The result is also written to `/run/windows-vm/kvm-status.json` and returned
by `GET /health` and `GET /status`.

---

## 4. Critical failure behavior (KVM missing)

If `KVM_REQUIRED=true` and KVM is unavailable:

- Windows is **not** booted automatically.
- When `VM_AUTOSTART=true`, the container logs:

```
[KVM] NOT AVAILABLE
[ERROR] KVM is required but /dev/kvm is unavailable
[ERROR] Windows VM will not start
```

  and exits with status 1 so the failure is visible in Render deploy logs.

- With the initial `VM_AUTOSTART=false` / `KVM_TEST_ONLY=true` the service
  keeps running the status API so you can inspect diagnostics without a
  restart loop.

Software emulation is only ever used when **all** of the following are true:

```
KVM_REQUIRED=false (or you accept the failure path)
ENABLE_TCG_FALLBACK=true
```

In that case the logs and `/health` clearly report
`KVM UNAVAILABLE - USING TCG SOFTWARE EMULATION`. TCG is extremely slow and is
never enabled silently.

### Render platform limitation

Render does not document `/dev/kvm` passthrough for Docker services. This
project's capability check is therefore the authoritative answer for your
service. If it reports `KVM NOT AVAILABLE`, the requested architecture
(full-speed Windows 10 with KVM) is not achievable on that instance, and the
project intentionally fails instead of pretending otherwise. Contact Render
support to ask whether nested virtualization/KVM device passthrough is
available for your workspace; until confirmed, use `KVM_TEST_ONLY=true`.

---

## 5. Persistent disk and single-instance rules

- The Render persistent disk is attached to one instance only.
- The Windows VM, its QCOW2 disk and the UEFI variable store live on it.
- Do **not** scale the service. Adding a disk disables zero-downtime deploys;
  Render stops the old instance before starting the new one.
- Disk snapshots (daily) can restore the Windows disk state if needed.

## 6. Shutdown behavior

Render sends `SIGTERM` and waits `maxShutdownDelaySeconds` (300 in
`render.yaml`). The entrypoint stops ngrok, then requests a clean ACPI
shutdown from Windows via the QEMU monitor, waits up to `VM_SHUTDOWN_TIMEOUT`
(default 180 s), then falls back to monitor `quit`, `SIGTERM` and finally
`SIGKILL`. Always allow the VM to shut down cleanly so the QCOW2 filesystem
stays consistent.

## 7. Environment groups (optional)

For multiple services sharing settings, define values in a Render Environment
Group and reference it from `render.yaml` with `fromGroup`. The VM service
itself must remain single-instance.

## 8. Validating `render.yaml`

```bash
render blueprints validate render.yaml
```

The Blueprint mirrors the Dashboard/API configuration. Render preserves
existing environment variables that are omitted from the Blueprint, so keep
this file in sync when changing settings.
