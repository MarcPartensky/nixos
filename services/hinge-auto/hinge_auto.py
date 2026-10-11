#!/usr/bin/env python3
"""Auto-like Hinge web (app.hinge.co), pilote par Playwright + Chromium.

Modes :
  login      Chromium VISIBLE (aucun headless) : tu te connectes (telephone + SMS),
             tu arrives sur le flux Discover, puis Entree dans le terminal = session
             persistee dans le profil. A lancer depuis une session graphique de marc.
  like       Profil persistant + boucle de likes dans Discover jusqu'a la limite
             journaliere ou l'epuisement du flux. Headless par defaut (serveur).
  calibrate  Vide la structure des boutons du flux Discover (textes, aria-labels,
             data-testid) pour affiner les selecteurs sans lire le DOM a la main.

Env :
  HINGE_USER_DATA_DIR  profil persistant (defaut /var/lib/hermes/hinge-auto/user-data)
  HINGE_HEADLESS       0|1 pour le mode like (defaut 1 = headless serveur)
  HINGE_MAX_LIKES      nombre max de likes avant arret (defaut 40, garde-fou)
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

# Selecteurs candidats pour le bouton Like d'une fiche (a calibrer sur le DOM reel).
LIKE_SELECTORS = [
    "button[aria-label*='like' i]",
    "[data-testid*='like' i]",
    "button:has(svg[aria-label*='Like'])",
    "button[title*='Like']",
]

# Boutons de confirmation du dialog apres un like.
CONFIRM_SELECTORS = [
    "button:has-text('Send Like')",
    "button:has-text('Send a Like')",
    "button:has-text('Like')",
    "text=Send Like",
    "text=Send a Like",
]

# Marqueurs de fin (aucun like possible / flux epuise).
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
    """Clique le premier selecteur qui matche ; renvoie le selecteur ou None."""
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
            "\nConnecte-toi dans la fenetre Chromium (telephone + code SMS), "
            "arrive sur le flux Discover, puis reviens ici et appuie sur Entree "
            "pour sauver la session... "
        )
        # laisser quelques secondes pour que les cookies/localStorage soient flushes
        time.sleep(2)
    finally:
        ctx.close()
    print("Session persistee dans " + DATA_DIR)


def do_calibrate(p):
    ctx = _ctx(p, headless=False)
    try:
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        page.goto(DISCOVER, wait_until="domcontentloaded")
        input("Va sur une fiche Discover, puis reviens et appuie sur Entree pour dump... ")
        print("=== BOUTONS ===")
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

        # Si la navigation n'a pas deja mene au flux, on tente l'URL Discover.
        if "discover" not in page.url.lower():
            page.goto(DISCOVER, wait_until="domcontentloaded")
            human_delay(3, 5)

        while sent < MAX_LIKES:
            txt = _page_text(page)
            if any(m in txt for m in END_MARKERS):
                print(f"[stop] flux epuise ou limite atteinte apres {sent} likes : marqueur trouve")
                break

            liked = click_first(page, LIKE_SELECTORS, timeout=4000)
            if not liked:
                print(f"[stop] aucun bouton Like trouve apres {sent} likes (page: {page.url})")
                break

            sent += 1
            print(f"[like] +1 (selecteur: {liked}) total={sent}")
            human_delay(1, 2)

            # Dialog de confirmation eventuel : l'envoyer si present, sinon la
            # fiche suivante apparait d'elle-meme.
            conf = click_first(page, CONFIRM_SELECTORS, timeout=2500)
            if conf:
                print(f"       confirm: {conf}")
            human_delay(1.5, 3.5)

        print(f"[done] {sent} likes envoyes")
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