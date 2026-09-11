#!/usr/bin/env python3
# =============================================================================
# tests/selenium_test.py
#
# Runs INSIDE the Windows 10 VM (not in the Linux container).
#
# It attaches Selenium to a normally running, GUI Chrome instance by default
# (no headless mode) and performs a harmless browse:
#   - opens a public test page
#   - prints the title
#   - saves a screenshot
#   - exits cleanly
#
# Default mode ("attach") expects Chrome to already run with:
#   chrome.exe --remote-debugging-port=9222 --user-data-dir=C:\chrome-profile
#
# Set SELENIUM_MODE=launch to let Selenium start Chrome itself (still a normal
# window, not headless). Selenium Manager resolves ChromeDriver automatically.
#
# Usage (inside Windows):
#   python selenium_test.py
#   set SELENIUM_MODE=launch && python selenium_test.py
# =============================================================================
from __future__ import annotations

import os
import sys
import time

DEFAULT_URL = "https://example.com"
DEFAULT_SCREENSHOT = r"C:\Users\Public\selenium_test.png"


def fail(message: str) -> None:
    print(f"[SELENIUM][ERROR] {message}", file=sys.stderr)
    sys.exit(1)


def main() -> int:
    try:
        from selenium import webdriver
        from selenium.webdriver.chrome.options import Options
        from selenium.webdriver.chrome.service import Service
    except ImportError:
        fail("Selenium is not installed. Run: pip install selenium")

    mode = os.environ.get("SELENIUM_MODE", "attach").strip().lower()
    url = os.environ.get("TEST_URL", DEFAULT_URL).strip()
    screenshot = os.environ.get("SCREENSHOT_PATH", DEFAULT_SCREENSHOT).strip()
    debugger_address = os.environ.get("CHROME_DEBUGGER_ADDRESS", "127.0.0.1:9222").strip()

    options = Options()
    if mode == "attach":
        # Attach to the already running, interactive Chrome GUI session.
        options.add_experimental_option("debuggerAddress", debugger_address)
        print(f"[SELENIUM] attaching to Chrome at {debugger_address}")
    else:
        # Launch a regular, visible Chrome window (explicitly NOT headless).
        options.add_argument("--start-maximized")
        options.add_argument("--remote-debugging-port=9222")
        options.add_argument("--user-data-dir=C:\\chrome-profile")
        options.add_argument("--no-first-run")
        options.add_argument("--no-default-browser-check")
        print("[SELENIUM] launching Chrome in normal GUI mode")

    driver = None
    try:
        driver = webdriver.Chrome(service=Service(), options=options)
        print(f"[SELENIUM] navigating to {url}")
        driver.get(url)
        time.sleep(2)

        title = driver.title
        print(f"[SELENIUM] page title: {title}")

        # Exercise common interactions to prove the browser is fully usable.
        driver.execute_script("window.scrollTo(0, document.body.scrollHeight);")
        time.sleep(1)
        driver.execute_script("window.scrollTo(0, 0);")

        driver.save_screenshot(screenshot)
        print(f"[SELENIUM] screenshot saved: {screenshot}")

        print("[SELENIUM] OK")
        return 0
    except Exception as exc:  # noqa: BLE001 - report any Selenium failure clearly
        fail(f"test failed: {exc}")
        return 1
    finally:
        if driver is not None:
            try:
                driver.quit()
                print("[SELENIUM] driver closed cleanly")
            except Exception:  # noqa: BLE001
                pass


if __name__ == "__main__":
    sys.exit(main())
