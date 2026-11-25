#!/usr/bin/env python3
"""Auto-like Hinge web (app.hinge.co), driven by Playwright + Chromium.

Modes:
  login      VISIBLE Chromium (no headless): you log in (phone + SMS),
             you reach the Discover feed, then Enter in the terminal = session
             persisted in the profile. To be run from a graphical marc session.
  like       Persistent profile + like loop in Discover until the daily
             limit or feed exhaustion. Headless by default (server).
  calibrate  Dumps the structure of the Discover feed buttons (texts, aria-labels,
             data-testid) to refine the selectors without reading the DOM by hand.

Env:
  HINGE_USER_DATA_DIR  persistent profile (default /var/lib/hermes/hinge-auto/user-data)
  HINGE_HEADLESS       0|1 for like mode (default 1 = server headless)
  HINGE_MAX_LIKES      max number of likes before stopping (default 40, safeguard)
"""
import os
import random
import sys
import time

from playwright.sync_api import sync_playwright

BASE = "https://app.hinge.co"
DISCOVER = BASE + "/discover"
DATA_DIR = os.environ.get("HINGE_USER_DATA_DIR", "/var/lib/hermes/hinge-auto/user-data")
MAX_LIKES = int(os.environ.get("HINGE_MAX_LIKES", "40"))

# Candidate selectors for a card's Like button (to calibrate on the real DOM).
LIKE_SELECTORS = [
    "button[aria-label*='like' i]",
    "[data-testid*='like' i]",
    "button:has(svg[aria-label*='Like'])",
    "button[title*='Like']",
]

# Confirmation buttons of the dialog after a like.
CONFIRM_SELECTORS = [
    "button:has-text('Send Like')",
    "button:has-text('Send a Like')",
    "button:has-text('Like')",
    "text=Send Like",
    "text=Send a Like",
]

# End markers (no like possible / feed exhausted).
END_MARKERS = [
    "all caught up",
    "out of likes",
    "no more likes",
    "seen everyone",
    "come back",
    "find more",
]


def human_delay(a=1.0, b=3.0):
    time.sleep(random.uniform(a, b))


def _ctx(p, headless):
    return p.chromium.launch_persistent_context(
        DATA_DIR,
        headless=headless,
        args=["--disable-blink-features=AutomationControlled"],
    )


def _page_text(page):
    try:
        return (page.locator("body").inner_text() or "").lower()
    except Exception:
        return ""


def click_first(page, selectors, timeout=6000):
    """Click the first selector that matches; return the selector or None."""
    for sel in selectors:
        try:
            el = page.locator(sel).first
            el.wait_for(state="visible", timeout=timeout)
            el.click()
            return sel
        except Exception:
            continue
    return None


def do_login(p):
    ctx = _ctx(p, headless=False)
    try:
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        page.goto(DISCOVER, wait_until="domcontentloaded")
        input(
            "\nLog in in the Chromium window (phone + SMS code), "
            "reach the Discover feed, then come back here and press Enter "
            "to save the session... "
        )
        # leave a few seconds so the cookies/localStorage get flushed
        time.sleep(2)
    finally:
        ctx.close()
    print("Session persisted in " + DATA_DIR)


def do_calibrate(p):
    ctx = _ctx(p, headless=False)
    try:
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        page.goto(DISCOVER, wait_until="domcontentloaded")
        input("Go to a Discover card, then come back and press Enter to dump... ")
        print("=== BUTTONS ===")
        for i, b in enumerate(page.locator("button").all()[:60]):
            try:
                label = b.get_attribute("aria-label") or ""
                tip = b.get_attribute("title") or ""
                tid = b.get_attribute("data-testid") or ""
                txt = (b.inner_text() or "").strip().replace("\n", " ")[:40]
                if label or tip or tid or txt:
                    print(f"[{i}] aria={label!r} title={tip!r} testid={tid!r} text={txt!r}")
            except Exception:
                continue
        print("=== TITLE === ", page.title())
        print("=== URL === ", page.url)
    finally:
        ctx.close()


def do_like(p, headless):
    ctx = _ctx(p, headless=headless)
    sent = 0
    try:
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        page.goto(DISCOVER, wait_until="domcontentloaded")
        human_delay(3, 5)

        # If the navigation did not already reach the feed, try the Discover URL.
        if "discover" not in page.url.lower():
            page.goto(DISCOVER, wait_until="domcontentloaded")
            human_delay(3, 5)

        while sent < MAX_LIKES:
            txt = _page_text(page)
            if any(m in txt for m in END_MARKERS):
                print(f"[stop] feed exhausted or limit reached after {sent} likes: marker found")
                break

            liked = click_first(page, LIKE_SELECTORS, timeout=4000)
            if not liked:
                print(f"[stop] no Like button found after {sent} likes (page: {page.url})")
                break

            sent += 1
            print(f"[like] +1 (selector: {liked}) total={sent}")
            human_delay(1, 2)

            # Possible confirmation dialog: send it if present, otherwise the
            # next card appears by itself.
            conf = click_first(page, CONFIRM_SELECTORS, timeout=2500)
            if conf:
                print(f"       confirm: {conf}")
            human_delay(1.5, 3.5)

        print(f"[done] {sent} likes sent")
    finally:
        ctx.close()


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "like"
    headless = os.environ.get("HINGE_HEADLESS", "1") != "0"
    with sync_playwright() as p:
        if mode == "login":
            do_login(p)
        elif mode == "calibrate":
            do_calibrate(p)
        else:
            do_like(p, headless)


if __name__ == "__main__":
    main()