#!/usr/bin/env python3
"""services/zabbix/seed.py : inventaire Zabbix par l'API (idempotent).

Zabbix garde son inventaire (hotes, items, declencheurs) dans SA base : le nix
pose le logiciel, ce script pose ce qui surveille quoi. Relance sans risque, un
objet existant est reconnu par son nom.

Lancement, sur le VPS (le frontal ecoute en loopback sur 9600) :

    python3 services/zabbix/seed.py --url http://127.0.0.1:9600 \
        --password "$(cat /root/zabbix-admin-password)" \
        --agent-ip 100.64.0.1 \
        --hosts tower anywhere laptop deck \
        --domains vault.marcpartensky.com mail.marcpartensky.com \
        --template-file /nix/store/...-zabbix-.../share/zabbix/templates/...

Ce qui est pose :

  * les hotes par agent (interface 10050) et le template Linux s'il est fourni ;
  * une sonde HTTP par domaine public : l'item compte les reponses 200 a 499
    comme vivantes, et le declencheur tire sur `nodata` (une cible morte, un
    item passe en unsupported et un tunnel tombe produisent tous les trois
    l'absence de donnees fraiches) ;
  * rien d'autre : les medias d'alerte et les actions restent a regler cote
    interface, comme le veut Zabbix.

Sans jeton d'API prealable : on se connecte avec le compte Admin (mot de passe
par defaut `zabbix` a la premiere installation, puis celui qu'on a pose), et le
script peut changer ce mot de passe via --new-admin-password.
"""
import argparse
import json
import sys
import urllib.error
import urllib.request

API = None
TOKEN = None


def rpc(method, params):
    payload = {"jsonrpc": "2.0", "method": method, "params": params, "id": 1}
    if TOKEN:
        # Le jeton de session va dans le CORPS (`auth`), pas dans un en-tete
        # Authorization : Zabbix 7.x reserve `Authorization: Bearer` aux jetons
        # d'API et repond « Not authorized » a un sessionid envoye ainsi.
        payload["auth"] = TOKEN
    req = urllib.request.Request(
        API,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json-rpc"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = json.load(resp)
    if "error" in body:
        raise RuntimeError(f"{method}: {body['error'].get('data', body['error'])}")
    return body["result"]


def login(user, password):
    global TOKEN
    res = rpc("user.login", {"username": user, "password": password})
    TOKEN = res["sessionid"] if isinstance(res, dict) else res


def ensure_group(name):
    found = rpc("hostgroup.get", {"filter": {"name": [name]}})
    if found:
        return found[0]["groupid"]
    return rpc("hostgroup.create", {"name": name})["groupids"][0]


def template_id(name):
    found = rpc("template.get", {"filter": {"host": [name]}})
    return found[0]["templateid"] if found else None


def ensure_host(name, groupid, agent_ip, tplid):
    found = rpc("host.get", {"filter": {"host": [name]}, "selectInterfaces": ["interfaceid", "ip", "port"]})
    if found:
        hid = found[0]["hostid"]
        # L'interface d'agent doit pointer sur l'adresse de CETTE machine : une
        # IP unique pour toute la flotte laisse les hotes injoignables (seuls les
        # checks actifs remonteraient, pas les items passifs du template).
        ifaces = found[0].get("interfaces") or []
        if ifaces and ifaces[0]["ip"] != agent_ip:
            rpc(
                "host.update",
                {
                    "hostid": hid,
                    "interfaces": [
                        {
                            "interfaceid": ifaces[0]["interfaceid"],
                            "type": 1,
                            "main": 1,
                            "useip": 1,
                            "ip": agent_ip,
                            "dns": "",
                            "port": "10050",
                        }
                    ],
                },
            )
            print(f"  ~ hote {name} : interface corrigee vers {agent_ip}")
        else:
            print(f"  = hote {name}")
        return hid, False
    params = {
        "host": name,
        "groups": [{"groupid": groupid}],
        "interfaces": [
            {"type": 1, "main": 1, "useip": 1, "ip": agent_ip, "dns": "", "port": "10050"}
        ],
    }
    if tplid:
        params["templates"] = [{"templateid": tplid}]
    hid = rpc("host.create", params)["hostids"][0]
    print(f"  + hote {name} (agent {agent_ip}:10050)")
    return hid, True


def ensure_http_probe(hostid, hostname, url):
    """Un item HTTP par domaine, plus le declencheur d'absence de donnees."""
    key = f"http.check[{url}]"
    found = rpc("item.get", {"hostids": hostid, "filter": {"key_": [key]}})
    if found:
        item = found[0]
        # Piege verifie : un item HTTP en `retrieve_mode: 1` (en-tetes seuls)
        # renvoie du TEXTE, donc un value_type numerique (3) le fait passer en
        # « not supported » et la sonde ne remonte plus rien (state=1). On le
        # corrige sur les items deja crees.
        if item.get("value_type") != "1":
            rpc("item.update", {"itemid": item["itemid"], "value_type": 1})
            print(f"    ~ sonde {url} : value_type corrige (texte)")
        else:
            print(f"    = sonde {url}")
        return
    rpc(
        "item.create",
        {
            "hostid": hostid,
            "name": f"Son HTTP {url}",
            "key_": key,
            "type": 19,  # HTTP agent
            "value_type": 1,  # texte : on ne garde que la presence/absence de donnee
            "url": url,
            "output_format": 0,
            "retrieve_mode": 1,  # en-tetes seulement
            "status_codes": "200-499",
            "follow_redirects": 1,
            "timeout": "10s",
            "delay": "60s",
            "history": "7d",
            "trends": "90d",
        },
    )
    rpc(
        "trigger.create",
        {
            "description": f"{url} ne repond plus (aucune donnee fraiche)",
            "expression": f"nodata(/{hostname}/{key},5m)=1",
            "priority": 4,  # High
            "manual_close": 1,
        },
    )
    print(f"    + sonde {url} + declencheur")


def ensure_external_hosts(groupid, domains):
    """Un hote par domaine, sans interface : Zabbix y met les sondes externes."""
    for d in domains:
        name = f"ext-{d.split('.')[0]}"
        found = rpc("host.get", {"filter": {"host": [name]}})
        if found:
            hid = found[0]["hostid"]
            print(f"  = hote {name}")
        else:
            hid = rpc(
                "host.create",
                {
                    "host": name,
                    "name": f"Sondes externes {d}",
                    "groups": [{"groupid": groupid}],
                    "interfaces": [],
                },
            )["hostids"][0]
            print(f"  + hote {name}")
        ensure_http_probe(hid, name, d)


def main():
    global API
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--user", default="Admin")
    ap.add_argument("--password", default="zabbix")
    ap.add_argument("--new-admin-password")
    ap.add_argument("--group", default="Flotte marc")
    ap.add_argument("--agent-ip", default="100.64.0.1")
    ap.add_argument("--hosts", nargs="*", default=[])
    ap.add_argument("--domains", nargs="*", default=[])
    ap.add_argument("--template-name", default="Linux by Zabbix agent")
    args = ap.parse_args()

    API = args.url.rstrip("/") + "/api_jsonrpc.php"
    login(args.user, args.password)
    print(f"connecte a {API}")

    if args.new_admin_password:
        me = rpc("user.get", {"filter": {"username": args.user}})[0]
        rpc("user.update", {"userid": me["userid"], "passwd": args.new_admin_password})
        print("mot de passe admin change")

    gid = ensure_group(args.group)
    tplid = template_id(args.template_name)
    print(f"groupe={gid} template={tplid or 'absent (a importer cote interface)'}")

    print("== machines ==")
    for h in args.hosts:
        # `nom=ip_tailnet` : l'interface d'agent de chaque hote doit porter SA
        # propre adresse (cf. ensure_host).
        name, _, ip = h.partition("=")
        ensure_host(name, gid, ip or args.agent_ip, tplid)

    print("== sondes externes ==")
    ensure_external_hosts(gid, args.domains)


if __name__ == "__main__":
    try:
        main()
    except urllib.error.URLError as exc:
        print(f"injoignable : {exc}", file=sys.stderr)
        raise SystemExit(2)
