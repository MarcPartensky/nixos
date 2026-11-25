#!/usr/bin/env python3
"""services/zabbix/seed.py: Zabbix inventory through the API (idempotent).

Zabbix keeps its inventory (hosts, items, triggers) in ITS database: nix
installs the software, this script sets up what monitors what. Safe to re-run, an
existing object is recognized by its name.

Run, on the VPS (the frontend listens on loopback on 9600):

    python3 services/zabbix/seed.py --url http://127.0.0.1:9600 \
        --password "$(cat /root/zabbix-admin-password)" \
        --agent-ip 100.64.0.1 \
        --hosts tower anywhere laptop deck \
        --domains vault.marcpartensky.com mail.marcpartensky.com \
        --template-file /nix/store/...-zabbix-.../share/zabbix/templates/...

What is set up:

  * hosts by agent (interface 10050) and the Linux template if provided;
  * an HTTP probe per public domain: the item counts 200 to 499 responses
    as alive, and the trigger fires on `nodata` (a dead target, an
    item turned unsupported and a down tunnel all three produce
    the absence of fresh data);
  * nothing else: alert media and actions remain to be configured on the
    interface side, as Zabbix intends.

Without a prior API token: we log in with the Admin account (password
default `zabbix` on the first install, then the one we set), and the
script can change this password via --new-admin-password.
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
        # The session token goes in the BODY (`auth`), not in an
        # Authorization header: Zabbix 7.x reserves `Authorization: Bearer` for API
        # tokens and answers "Not authorized" to a sessionid sent that way.
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
        # The agent interface must point to THIS machine's address: a
        # single IP for the whole fleet leaves hosts unreachable (only
        # active checks would report, not the template's passive items).
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
            print(f"  ~ host {name}: interface fixed to {agent_ip}")
        else:
            print(f"  = host {name}")
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
    print(f"  + host {name} (agent {agent_ip}:10050)")
    return hid, True


def ensure_http_probe(hostid, hostname, url):
    """One HTTP item per domain, plus the no-data trigger."""
    key = f"http.check[{url}]"
    found = rpc("item.get", {"hostids": hostid, "filter": {"key_": [key]}})
    if found:
        item = found[0]
        # Verified trap: an HTTP item in `retrieve_mode: 1` (headers only)
        # returns TEXT, so a numeric value_type (3) makes it go
        # "not supported" and the probe no longer reports anything (state=1). We
        # fix it on already-created items.
        if item.get("value_type") != "1":
            rpc("item.update", {"itemid": item["itemid"], "value_type": 1})
            print(f"    ~ probe {url}: value_type fixed (text)")
        else:
            print(f"    = probe {url}")
        return
    rpc(
        "item.create",
        {
            "hostid": hostid,
            "name": f"HTTP probe {url}",
            "key_": key,
            "type": 19,  # HTTP agent
            "value_type": 1,  # text: we only keep the presence/absence of data
            "url": url,
            "output_format": 0,
            "retrieve_mode": 1,  # headers only
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
            "description": f"{url} no longer responds (no fresh data)",
            "expression": f"nodata(/{hostname}/{key},5m)=1",
            "priority": 4,  # High
            "manual_close": 1,
        },
    )
    print(f"    + probe {url} + trigger")


def ensure_external_hosts(groupid, domains):
    """One host per domain, without interface: Zabbix puts the external probes there."""
    for d in domains:
        name = f"ext-{d.split('.')[0]}"
        found = rpc("host.get", {"filter": {"host": [name]}})
        if found:
            hid = found[0]["hostid"]
            print(f"  = host {name}")
        else:
            hid = rpc(
                "host.create",
                {
                    "host": name,
                    "name": f"External probes {d}",
                    "groups": [{"groupid": groupid}],
                    "interfaces": [],
                },
            )["hostids"][0]
            print(f"  + host {name}")
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
    print(f"connected to {API}")

    if args.new_admin_password:
        me = rpc("user.get", {"filter": {"username": args.user}})[0]
        rpc("user.update", {"userid": me["userid"], "passwd": args.new_admin_password})
        print("admin password changed")

    gid = ensure_group(args.group)
    tplid = template_id(args.template_name)
    print(f"group={gid} template={tplid or 'absent (to import on the interface side)'}")

    print("== machines ==")
    for h in args.hosts:
        # `name=tailnet_ip`: each host's agent interface must carry ITS
        # own address (see ensure_host).
        name, _, ip = h.partition("=")
        ensure_host(name, gid, ip or args.agent_ip, tplid)

    print("== external probes ==")
    ensure_external_hosts(gid, args.domains)


if __name__ == "__main__":
    try:
        main()
    except urllib.error.URLError as exc:
        print(f"unreachable: {exc}", file=sys.stderr)
        raise SystemExit(2)
