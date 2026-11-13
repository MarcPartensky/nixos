#!/usr/bin/env python3
"""services/uptime-kuma/seed.py : compte admin, sondes et notification (idempotent).

Uptime Kuma garde ses sondes dans son SQLite : le nix pose le logiciel, ce
script pose ce qui est surveille. Relancer le script ne cree pas de doublon, un
moniteur existant est reconnu par son nom.

Lancement (sur le VPS, la ou kuma ecoute en loopback) :

    nix shell --impure --expr 'with (builtins.getFlake
      "/nix/store/pgy8nq09hh4mdgr30ir9v0lcjpz34vxb-source").legacyPackages.x86_64-linux;
      python3.withPackages (p: [ p.uptime-kuma-api ])' -c \
      python3 services/uptime-kuma/seed.py \
        --user marc --password '...' \
        --domains vault.marcpartensky.com mail.marcpartensky.com ... \
        --hosts tower=100.64.0.3 anywhere=100.64.0.1 laptop=100.64.0.4 deck=100.64.0.2

Deux familles de sondes, volontairement :

  * domaines PUBLICS (HTTP, 200 a 499 accepte, redirections suivies) : c'est la
    seule mesure qui attrape une panne d'exposition (tunnel newt tombe, cible
    Pangolin morte) alors que toutes les machines vont bien ;
  * machines du TAILNET (TCP sur 22) : ping ICMP impossible, le service tourne en
    DynamicUser avec AmbientCapabilities = "" (pas de socket brut) ; le port SSH
    est un aussi bon temoin de vie.

L'alerte part par MAIL vers stalwart (127.0.0.1:25 sur le VPS) : c'est le seul
canal qui survit a une panne de tower, ou vivent Gotify et Matrix.
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
    ap.add_argument("--hosts", nargs="*", default=[], help="nom=ip_tailnet")
    ap.add_argument("--smtp-to", default="marc@marcpartensky.com")
    ap.add_argument("--smtp-from", default="alerts@marcpartensky.com")
    args = ap.parse_args()

    # Le premier setup prend quelques secondes sur un petit VPS (creation de la
    # base + migration) : le delai par defaut de la librairie (10 s) expire et le
    # compte n'est jamais cree (verifie : kuma reste en « No user, need setup »).
    # La signature de 1.2.1 est (url, timeout, headers, ssl_verify, wait_events) :
    # c'est `timeout` qui borne l'attente de l'accuse de reception.
    api = UptimeKumaApi(args.url, timeout=120)

    # Premier lancement : kuma n'a pas encore d'utilisateur. Une fois fait,
    # setup() leve une exception, qu'on ignore.
    try:
        api.setup(args.user, args.password)
        print("compte admin cree")
    except Exception as exc:  # noqa: BLE001
        print(f"setup: {type(exc).__name__}")

    try:
        api.login(args.user, args.password)
    except Exception as exc:  # noqa: BLE001
        # Un setup precedent a pu expirer en cours de route : on retente une fois.
        print(f"login echoue ({exc}), nouvelle tentative de setup")
        api.setup(args.user, args.password)
        api.login(args.user, args.password)
    print(f"connecte a {args.url}")

    # Notification mail d'abord : elle est attachee des la creation des sondes.
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
            print(f"notification mail-vps creee (id {nid})")
        else:
            nid = notifs["mail-vps"]["id"]
    except Exception as exc:  # noqa: BLE001
        # Les kwargs d'une notification varient selon la version de la librairie
        # (smtpSecure / smtpSecurity, etc.). On ne bloque pas les sondes pour
        # autant : l'erreur est imprimee et la notification se pose a la main.
        print(f"notification mail-vps NON posee : {type(exc).__name__} {exc}")
    attached = {str(nid): True} if nid else None

    existing = {m["name"]: m for m in api.get_monitors()}

    def ensure(kind, name, **kw):
        if name in existing:
            print(f"  = {name}")
            return
        api.add_monitor(name=name, type=kind, notificationIDList=attached, **kw)
        print(f"  + {name}")

    print("== domaines publics (bout en bout) ==")
    for d in args.domains:
        ensure(
            MonitorType.HTTP,
            f"domaine {d}",
            url=f"https://{d}",
            interval=60,
            retryInterval=60,
            maxretries=2,
            # Kuma 2.x valide la liste : les plages doivent etre des centaines
            # entieres ('200-299'...), pas une plage arbitraire ('200-499').
            accepted_statuscodes=["200-299", "300-399", "400-499"],
        )

    print("== machines du tailnet ==")
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

    print("== recapitulatif ==")
    for m in api.get_monitors():
        print(f"  {m['name']:38s} {m['type']:5s} {'actif' if m['active'] else 'inactif'}")


if __name__ == "__main__":
    sys.exit(main())
