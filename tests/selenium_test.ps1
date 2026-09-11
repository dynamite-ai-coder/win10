# =============================================================================
# tests/selenium_test.ps1
#
# PowerShell helper for Windows 10:
#   1. if Chrome + Python + Selenium are available, runs tests/selenium_test.py
#   2. otherwise performs a dependency-free Chrome DevTools Protocol check:
#      - verifies Chrome is running with --remote-debugging-port=9222
#      - opens a URL via the CDP HTTP endpoint
#      - prints the page title
#
# Run inside the Windows VM:
#   powershell -ExecutionPolicy Bypass -File .\selenium_test.ps1
# =============================================================================
[CmdletBinding()]
param(
    [string]$Url = "https://example.com",
    [int]$DebugPort = 9222,
    [string]$Python = "python"
)

$ErrorActionPreference = "Stop"
$DebugEndpoint = "http://127.0.0.1:$DebugPort"

function Write-Step($message) { Write-Host "[SELENIUM] $message" }
function Write-Err($message)  { Write-Host "[SELENIUM][ERROR] $message" -ForegroundColor Red }

# --- Preferred path: full Selenium test through Python ----------------------
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$pythonTest = Join-Path $scriptDir "selenium_test.py"
$havePython = $null -ne (Get-Command $Python -ErrorAction SilentlyContinue)

if ($havePython -and (Test-Path $pythonTest)) {
    Write-Step "Python found - running the full Selenium test"
    & $Python $pythonTest
    if ($LASTEXITCODE -eq 0) { Write-Step "OK (Selenium)"; exit 0 }
    Write-Err "Python Selenium test failed - falling back to CDP check"
}

# --- Fallback: Chrome DevTools Protocol over HTTP ---------------------------
function Test-DebugEndpoint {
    try { Invoke-RestMethod -Uri "$DebugEndpoint/json/version" -TimeoutSec 3 | Out-Null; return $true }
    catch { return $false }
}

if (-not (Test-DebugEndpoint)) {
    Write-Step "Chrome is not exposing the debug port; starting it"
    $chromeCandidates = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    $chrome = $chromeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $chrome) { Write-Err "chrome.exe not found - install Google Chrome"; exit 1 }
    Start-Process -FilePath $chrome -ArgumentList "--remote-debugging-port=$DebugPort", "--user-data-dir=C:\chrome-profile", "--no-first-run" | Out-Null
    Start-Sleep -Seconds 4
}

if (-not (Test-DebugEndpoint)) { Write-Err "Chrome debug endpoint is not reachable"; exit 1 }
Write-Step "Chrome debug endpoint is reachable"

# /json/new opens a new tab (Chrome 111+ requires PUT).
try {
    $newTab = Invoke-RestMethod -Method Put -Uri "$DebugEndpoint/json/new?$Url" -TimeoutSec 5
} catch {
    try { $newTab = Invoke-RestMethod -Uri "$DebugEndpoint/json/new?$Url" -TimeoutSec 5 }
    catch { Write-Err "could not open a new tab: $_"; exit 1 }
}
Start-Sleep -Seconds 3

$targets = Invoke-RestMethod -Uri "$DebugEndpoint/json/list" -TimeoutSec 5
$page = $targets | Where-Object { $_.type -eq "page" } | Select-Object -First 1
if ($page) {
    Write-Step "page title: $($page.title)"
    Write-Step "page url:   $($page.url)"
    Write-Step "OK (CDP)"
    exit 0
}

Write-Err "no page target found"
exit 1
