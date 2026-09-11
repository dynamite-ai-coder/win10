# Windows 10 Setup Guide

This guide covers everything that happens **inside the Windows 10 VM** after
the Render container (QEMU + KVM) is running. It does not cover Render
deployment; see [../RENDER.md](../RENDER.md) for that.

> The project does **not** bundle or redistribute Windows. You must provide
> your own legally obtained Windows 10 installation media.

---

## 1. Provide the Windows 10 installation ISO

The container expects the ISO under the persistent disk:

```
/var/lib/windows/iso/windows10.iso
```

Two supported ways to get it there:

### Option A - Render Shell + direct download (recommended)

1. Open the `win10` service in the Render Dashboard.
2. Open the **Shell** tab (available on paid services).
3. Download a legally obtained ISO directly into the persistent disk:

```bash
mkdir -p /var/lib/windows/iso
curl -fL --retry 3 -o /var/lib/windows/iso/windows10.iso \
  "YOUR_WINDOWS_ISO_URL"
```

### Option B - `WINDOWS_ISO_URL` environment variable

Set `WINDOWS_ISO_URL` to your own download URL. On startup
`scripts/setup-disk.sh` downloads it into `/var/lib/windows/iso/windows10.iso`
when missing. Never commit an ISO to the repository.

### VirtIO drivers ISO

A VirtIO disk/network for Windows needs the virtio-win drivers. Provide:

```
/var/lib/windows/iso/virtio-win.iso
```

Download it yourself from the official Fedora project and place it on the
persistent disk with `curl`, or set `VIRTIO_ISO_URL`. If you prefer to avoid
VirtIO drivers entirely, set `VM_DISK_BUS=sata` (slower, but installs without
extra drivers).

---

## 2. Install Windows 10

1. Ensure `VM_BOOT_DEVICE=auto` and that the install marker does not exist
   (`/var/lib/windows/state/windows_installed`). The startup scripts then boot
   from the CD-ROM first.
2. Start the VM (Render Shell):

```bash
start-vm
check-vm
```

3. Connect to the Windows desktop over RDP (see [section 6](#6-enable-remote-desktop-rdp)).
   Until RDP is configured you can also attach a temporary VNC server if you
   change `VM_DISPLAY` / add `-vnc`, but this is not exposed publicly and is
   only for troubleshooting.
4. Walk through the Windows installer:
   - choose **Custom installation**
   - the VirtIO disk is invisible until you load the driver:
     **Load driver → Browse → virtio-win CD → `viostor\w10\amd64`**
   - select the now-visible disk and install
5. On first boot install the remaining VirtIO devices:
   - open the virtio-win CD in Explorer and run `virtio-win-gt-x64.msi`
   - install the network driver (`NetKVM\w10\amd64`) if networking is missing
6. Once Windows is installed and you can log in, mark the installation so the
   VM boots from disk on the next start:

```bash
date -u +%Y-%m-%dT%H:%M:%SZ > /var/lib/windows/state/windows_installed
```

On future container restarts `-boot order=c` (the QCOW2 disk) is used
automatically. The QCOW2 disk, UEFI variables and metadata all live on the
persistent disk, so state survives redeploys.

---

## 3. UEFI / OVMF notes

- The VM uses Q35 + OVMF UEFI firmware (`/usr/share/OVMF/OVMF_CODE_4M.fd`).
- The per-VM NVRAM file is copied to `/var/lib/windows/uefi/OVMF_VARS.fd` the
  first time and persists afterwards.
- If Windows Setup starts in a boot loop, enter the UEFI setup with `Esc`
  during the splash (QEMU's OVMF menu) and verify the boot order.
- Secure Boot is intentionally **not** enabled (the OVMF secure-boot variant is
  not used) to avoid signed-driver friction.

---

## 4. Install Chrome

Inside Windows, download and install Google Chrome from the official site
(`https://www.google.com/chrome/`) or with PowerShell:

```powershell
$url = "https://dl.google.com/chrome/install/latest/chrome_installer.exe"
Invoke-WebRequest -Uri $url -OutFile "$env:TEMP\chrome_installer.exe"
Start-Process -FilePath "$env:TEMP\chrome_installer.exe" -ArgumentList "/silent /install" -Wait
```

Verify: `& "C:\Program Files\Google\Chrome\Application\chrome.exe" --version`

---

## 5. ChromeDriver / Selenium

Selenium 4.6+ includes **Selenium Manager**, which downloads the matching
ChromeDriver automatically - no manual driver pinning is required.

1. Install Python from `https://www.python.org/downloads/windows/` (check
   *Add python.exe to PATH*).
2. Install Selenium:

```powershell
python -m pip install --upgrade pip
python -m pip install selenium
```

3. Copy `tests/selenium_test.py` and `tests/selenium_test.ps1` from the
   repository into the VM (for example via the persistent disk, a shared
   folder, or `curl` from your Git host).

4. Start Chrome in normal (non-headless) GUI mode with remote debugging:

```powershell
& "C:\Program Files\Google\Chrome\Application\chrome.exe" `
  --remote-debugging-port=9222 `
  --user-data-dir=C:\chrome-profile
```

5. Run the test:

```powershell
python C:\selenium_test.py
# or: set SELENIUM_MODE=launch && python C:\selenium_test.py
```

The test attaches to the visible browser, opens `https://example.com`, prints
the title, exercises scrolling, saves a screenshot and closes the driver. It
never runs headless.

### Manual ChromeDriver fallback

If Selenium Manager is blocked by network policy:

1. Check the installed Chrome version (`chrome://version`).
2. Download the matching driver from the official Chrome for Testing
   endpoint (`https://googlechromelabs.github.io/chrome-for-testing/`).
3. Put `chromedriver.exe` in `C:\Windows` or on `PATH`, then run:

```powershell
$env:SELENIUM_MODE = "launch"
python C:\selenium_test.py
```

---

## 6. Enable Remote Desktop (RDP)

1. `Win + R` → `sysdm.cpl` → **Remote** tab → enable
   *Allow remote connections to this computer*.
2. Recommended: disable *Require computers to use Network Level
   Authentication* only if your client cannot do NLA; otherwise keep it on.
3. Ensure the account you connect with has a **strong password**.
4. Confirm the RDP listener:

```powershell
Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections
```

`fDenyTSConnections` must be `0`. To enable from PowerShell directly:

```powershell
Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
Set-Service -Name TermService -StartupType Automatic
Start-Service TermService
```

---

## 7. Windows Firewall

The QEMU network forwards the container's `127.0.0.1:3389` to the VM's
`:3389`. Traffic arrives over the emulated LAN, so the RDP rule typically only
needs to cover the **Private/Domain** profile. From an elevated PowerShell:

```powershell
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
Get-NetFirewallRule -DisplayGroup "Remote Desktop" | Select DisplayName,Enabled,Profile
```

Do **not** open additional inbound ports. Everything external arrives through
the ngrok tunnel; port 3389 is never published publicly by Render or by QEMU
(it binds `127.0.0.1` only).

---

## 8. Test RDP

From the container (Render Shell):

```bash
# RDP is only reachable locally inside the container; verify QEMU forwarding
timeout 3 bash -c 'cat < /dev/null > /dev/tcp/127.0.0.1/3389' \
  && echo "RDP port reachable inside container"
```

From your own computer, first start the ngrok tunnel if it is not already
running (see [README.md](../README.md#ngrok-and-remote-access)), then connect
to the printed `host:port` with a client (see
[README.md](../README.md#rdp-connection-procedure)).

---

## 9. Test Selenium

1. Make sure Chrome is open in the Windows desktop session.
2. Run `python C:\selenium_test.py`.
3. Expected output:

```
[SELENIUM] attaching to Chrome at 127.0.0.1:9222
[SELENIUM] navigating to https://example.com
[SELENIUM] page title: Example Domain
[SELENIUM] screenshot saved: C:\Users\Public\selenium_test.png
[SELENIUM] OK
```

Supported interactions: clicking buttons, filling forms, scrolling, selecting
elements, JavaScript execution, screenshots, downloads (`--user-data-dir` may
prompt once for a download location) and uploads (`send_keys` on a file input,
subject to Windows/browser permissions).

---

## 10. Auto-boot on future Render restarts

1. Mark the installation complete (once):

```bash
date -u +%Y-%m-%dT%H:%M:%SZ > /var/lib/windows/state/windows_installed
```

2. In the Render Dashboard set `VM_AUTOSTART=true` (and `KVM_TEST_ONLY=false`).
3. On every container start the entrypoint runs KVM diagnostics, sees the
   marker, boots the VM from the QCOW2 disk and restarts the tunnels.
4. Verify with `check-vm` or `GET /health`.
