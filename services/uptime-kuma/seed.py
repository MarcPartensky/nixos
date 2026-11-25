#!/usr/bin/env python3
"""services/uptime-kuma/seed.py: admin account, probes and notification (idempotent).

Uptime Kuma keeps its probes in its SQLite DB: nix installs the software, this
script installs what is monitored. Re-running the script does not create
duplicates, an existing monitor is recognized by its name.

Run (on the VPS, where kuma listens on loopback):

    nix shell --impure --expr 'with (builtins.getFlake
      "/nix/store/pgy8nq09hh4mdgr30ir9v0lcjpz34vxb-source").legacyPackages.x86_64-linux;
      python3.withPackages (p: [ p.uptime-kuma-api ])' -c \
      python3 services/uptime-kuma/seed.py \
        --user marc --password redacted-secret \
        --domains vault.marcpartensky.com mail.marcpartensky.com ... \
        --hosts tower=100.64.0.3 anywhere=100.64.0.1 laptop=100.64.0.4 deck=100.64.0.2

Two families of probes, deliberately:

  * PUBLIC domains (HTTP, 200 to 499 accepted, redirects followed): this is the
    only measurement that catches an exposure outage (newt tunnel down, dead
    Pangolin target) while all the machines are fine;
  * TAILNET machines (TCP on 22): ICMP ping impossible, the service runs as
    DynamicUser with AmbientCapabilities = "" (no raw socket); the SSH port
    is just as good a liveness signal.

The alert goes out by MAIL to stalwart (127.0.0.1:25 on the VPS): it is the only
channel that survives a tower outage, where Gotify and Matrix live.
"""
import argparse
import sys

from uptime_kuma_api import MonitorType, NotificationType, UptimeKumaApi


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:3001")
    ap.add_argument("--user", default="marc")
    ap.add_argument("--password", required=True)
    ap.add_argument("--domains", nargs="*", default=[])
    ap.add_argument("--hosts", nargs="*", default=[], help="name=ip_tailnet")
    ap.add_argument("--smtp-to", default="marc@marcpartensky.com")
    ap.add_argument("--smtp-from", default="alerts@marcpartensky.com")
    args = ap.parse_args()

    # The first setup takes a few seconds on a small VPS (DB creation + migration):
    # the library's default delay (10 s) expires and the account is never created
    # (verified: kuma stays at "No user, need setup").
    # The 1.2.1 signature is (url, timeout, headers, ssl_verify, wait_events):
    # it is `timeout` that bounds the wait for the acknowledgement.
    api = UptimeKumaApi(args.url, timeout=120)

    # First run: kuma does not have a user yet. Once done,
    # setup() raises an exception, which we ignore.
    try:
        api.setup(args.user, args.password)
        print("admin account created")
    except Exception as exc:  # noqa: BLE001
        print(f"setup: {type(exc).__name__}")

    try:
        api.login(args.user, args.password)
    except Exception as exc:  # noqa: BLE001
        # A previous setup may have timed out along the way: we retry once.
        print(f"login failed ({exc}), retrying setup")
        api.setup(args.user, args.password)
        api.login(args.user, args.password)
    print(f"connected to {args.url}")

    # Mail notification first: it is attached as soon as the probes are created.
    nid = None
    try:
        notifs = {n["name"]: n for n in api.get_notifications()}
        if "mail-vps" not in notifs:
            nid = api.add_notification(
                name="mail-vps",
                type=NotificationType.SMTP,
                smtpHost="127.0.0.1",
                smtpPort=25,
                smtpSecure=False,
                smtpFrom=args.smtp_from,
                smtpTo=args.smtp_to,
                smtpIgnoreTLSError=True,
                isDefault=True,
            )["id"]
            print(f"mail-vps notification created (id {nid})")
        else:
            nid = notifs["mail-vps"]["id"]
    except Exception as exc:  # noqa: BLE001
        # A notification's kwargs vary with the library version
        # (smtpSecure / smtpSecurity, etc.). We do not block the probes
        # for all that: the error is printed and the notification is set by hand.
        print(f"mail-vps notification NOT set: {type(exc).__name__} {exc}")
    attached = {str(nid): True} if nid else None

    existing = {m["name"]: m for m in api.get_monitors()}

    def ensure(kind, name, **kw):
        if name in existing:
            print(f"  = {name}")
            return
        api.add_monitor(name=name, type=kind, notificationIDList=attached, **kw)
        print(f"  + {name}")

    print("== public domains (end to end) ==")
    for d in args.domains:
        ensure(
            MonitorType.HTTP,
            f"domain {d}",
            url=f"https://{d}",
            interval=60,
            retryInterval=60,
            maxretries=2,
            # Kuma 2.x validates the list: the ranges must be whole hundreds
            # ('200-299'...), not an arbitrary range ('200-499').
            accepted_statuscodes=["200-299", "300-399", "400-499"],
        )

    print("== tailnet machines ==")
    for item in args.hosts:
        name, _, ip = item.partition("=")
        ensure(
            MonitorType.PORT,
            f"machine {name}",
            hostname=ip,
            port=22,
            interval=60,
            retryInterval=60,
            maxretries=2,
        )

    print("== summary ==")
    for m in api.get_monitors():
        print(f"  {m['name']:38s} {m['type']:5s} {'active' if m['active'] else 'inactive'}")


if __name__ == "__main__":
    sys.exit(main())
