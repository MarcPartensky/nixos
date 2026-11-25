#!/usr/bin/env python3
"""hermes-broker: la seule porte vers root pour l'agent Hermes.

L'agent (utilisateur `hermes`) depose une demande sur un socket unix. Le broker
la publie sur une page HTTPS et arme en meme temps tous les canaux de preuve :

  - mot de passe  : PAM sur le compte de marc (pamtester), rien de nouveau a retenir
  - touch-id      : popup natif sur le Mac de marc. Le broker (root) joint le Mac
                    par SSH et lance un helper du store Nix (root-owned, immuable)
                    qui ne rend 0 qu'apres un vrai match d'empreinte
  - passkey       : WebAuthn, n'importe quel authentificateur (Touch ID du Mac via
                    Chrome, empreinte du telephone, Bitwarden, cle materielle)

La premiere preuve valide gagne ; les autres deviennent inutilisables parce que
la demande est retiree de la table. Toute execution root est journalisee.

Ce que ce fichier ne fait PAS : parler Matrix (l'agent previent marc lui-meme),
ni stocker de secret (PAM verifie le mot de passe du systeme, les cles publiques
WebAuthn sont dans creds.json).
"""

import base64
import hashlib
import json
import os
import secrets
import shlex
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import p256

SOCK_PATH = os.environ.get("BROKER_SOCK", "/run/hermes-broker/broker.sock")
STATE_DIR = os.environ.get("BROKER_STATE", "/var/lib/hermes-broker")
CREDS_PATH = os.path.join(STATE_DIR, "creds.json")
AUDIT_PATH = os.path.join(STATE_DIR, "audit.jsonl")
PORT = int(os.environ.get("BROKER_PORT", "9188"))
RP_ID = os.environ.get("BROKER_RP_ID", "broker.marcpartensky.com")
ORIGIN = os.environ.get("BROKER_ORIGIN", "https://" + RP_ID)
TTL = int(os.environ.get("BROKER_TTL", "300"))
EXEC_TIMEOUT = int(os.environ.get("BROKER_EXEC_TIMEOUT", "900"))
PAM_USER = os.environ.get("BROKER_PAM_USER", "marc")
PAMTESTER = os.environ.get("BROKER_PAMTESTER", "pamtester")
# Canal Touch ID : commande ssh (root) vers le Mac, helper distant, delai.
TOUCHID_SSH = shlex.split(os.environ.get("BROKER_TOUCHID_SSH", ""))
TOUCHID_REMOTE = os.environ.get("BROKER_TOUCHID_REMOTE", "/run/current-system/sw/bin/hermes-touch-id")
TOUCHID_TIMEOUT = int(os.environ.get("BROKER_TOUCHID_TIMEOUT", "110"))
CALLER_GROUP = "hermes"
MAX_ATTEMPTS = 5
MAX_OUTPUT = 200_000
EXEC_ENV = {
    "PATH": "/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin",
    "HOME": "/root",
    "LANG": "C.UTF-8",
}

_lock = threading.Lock()
REQUESTS = {}
ENROLLMENTS = {}


# --- petits utilitaires ------------------------------------------------------


def b64u_encode(raw):
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def b64u_decode(text):
    pad = "=" * (-len(text) % 4)
    return base64.urlsafe_b64decode(text + pad)


def now():
    return int(time.time())


def requested_attachment(body):
    """Restriction d'authentificateur demandee par la page.

    "platform" = materiel de la machine uniquement (Touch ID du Mac, empreinte du
    telephone). Absent = tout, y compris Bitwarden ou une cle USB. C'est ce qui
    evite que Chrome propose Bitwarden quand marc veut son doigt sur le Mac.
    """
    value = (body or {}).get("attachment")
    return value if value in ("platform", "cross-platform") else None


def prune_challenges(store):
    """Un challenge WebAuthn ne vaut que 10 min ; on oublie les autres."""
    cutoff = now()
    for key in [k for k, exp in store.items() if exp < cutoff]:
        store.pop(key, None)


def client_data_challenge(raw):
    try:
        data = json.loads(raw.decode())
    except (ValueError, UnicodeDecodeError):
        raise ValueError("clientDataJSON illisible")
    challenge = data.get("challenge")
    if not isinstance(challenge, str) or not challenge:
        raise ValueError("challenge absente du clientDataJSON")
    return challenge


def audit(entry):
    entry["ts"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    line = json.dumps(entry, ensure_ascii=False)
    with open(AUDIT_PATH, "a") as handle:
        handle.write(line + "\n")
    print("audit " + line, flush=True)


def load_creds():
    try:
        with open(CREDS_PATH) as handle:
            return json.load(handle)
    except FileNotFoundError:
        return []


def save_creds(creds):
    tmp = CREDS_PATH + ".tmp"
    with open(tmp, "w") as handle:
        json.dump(creds, handle, indent=1)
    os.replace(tmp, CREDS_PATH)
    os.chmod(CREDS_PATH, 0o600)


def check_password(password):
    """Verifie le mot de passe systeme de marc via PAM. Aucun secret stocke ici."""
    try:
        proc = subprocess.run(
            [PAMTESTER, "login", PAM_USER, "authenticate"],
            input=password + "\n",
            capture_output=True,
            text=True,
            timeout=20,
        )
        return proc.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


# --- WebAuthn ----------------------------------------------------------------


def auth_data_parse(raw):
    if len(raw) < 37:
        raise ValueError("authData trop court")
    parsed = {
        "rp_id_hash": raw[:32],
        "flags": raw[32],
        "sign_count": int.from_bytes(raw[33:37], "big"),
    }
    if raw[32] & 0x40:  # AT: attested credential data present
        off = 37
        parsed["aaguid"] = raw[off : off + 16]
        off += 16
        cred_id_len = int.from_bytes(raw[off : off + 2], "big")
        off += 2
        parsed["cred_id"] = raw[off : off + cred_id_len]
        off += cred_id_len
        cose, _ = p256.cbor_decode(raw, off)
        parsed["cose"] = cose
    return parsed


def verify_client_data(raw, expected_type, challenge, origin):
    data = json.loads(raw.decode())
    if data.get("type") != expected_type:
        raise ValueError("type clientData invalide: %r" % data.get("type"))
    if data.get("challenge") != b64u_encode(challenge):
        raise ValueError("challenge different")
    if data.get("origin") != origin:
        raise ValueError("origine refusee: %r" % data.get("origin"))
    return data


def webauthn_register(challenge, client_data_raw, attestation_raw, name):
    verify_client_data(client_data_raw, "webauthn.create", challenge, ORIGIN)
    attestation, _ = p256.cbor_decode(attestation_raw)
    auth_data = auth_data_parse(attestation["authData"])
    if auth_data["rp_id_hash"] != hashlib.sha256(RP_ID.encode()).digest():
        raise ValueError("rpIdHash ne correspond pas")
    if not auth_data["flags"] & 0x01:
        raise ValueError("flag user-present absent")
    if not auth_data["flags"] & 0x04:
        raise ValueError("verification utilisateur absente (biometrie/PIN requis)")
    if "cose" not in auth_data:
        raise ValueError("pas de cle publique dans l'attestation")
    point = p256.cose_to_point(auth_data["cose"])
    if not p256.on_curve(point):
        raise ValueError("cle publique hors courbe")
    creds = load_creds()
    cred_id = b64u_encode(auth_data["cred_id"])
    creds = [c for c in creds if c["id"] != cred_id]
    creds.append(
        {
            "id": cred_id,
            "pubkey": p256.point_to_bytes(point).hex(),
            "sign_count": auth_data["sign_count"],
            "aaguid": auth_data["aaguid"].hex(),
            "name": name.strip()[:60] or "passkey",
            "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
    )
    save_creds(creds)
    return creds[-1]


def webauthn_assert(challenge, cred_id, client_data_raw, auth_data_raw, signature_der):
    creds = load_creds()
    cred = next((c for c in creds if c["id"] == cred_id), None)
    if cred is None:
        raise ValueError("credential inconnu")
    verify_client_data(client_data_raw, "webauthn.get", challenge, ORIGIN)
    auth_data = auth_data_parse(auth_data_raw)
    if auth_data["rp_id_hash"] != hashlib.sha256(RP_ID.encode()).digest():
        raise ValueError("rpIdHash ne correspond pas")
    if not auth_data["flags"] & 0x01:
        raise ValueError("flag user-present absent")
    if not auth_data["flags"] & 0x04:
        raise ValueError("verification utilisateur absente")
    point = p256.point_from_bytes(bytes.fromhex(cred["pubkey"]))
    message = auth_data_raw + hashlib.sha256(client_data_raw).digest()
    if not p256.verify_ecdsa_sha256(point, message, signature_der):
        raise ValueError("signature invalide")
    if auth_data["sign_count"] and cred.get("sign_count") and auth_data["sign_count"] <= cred["sign_count"]:
        print("webauthn: compteur non croissant pour %s (tolere)" % cred_id, flush=True)
    cred["sign_count"] = auth_data["sign_count"]
    save_creds(creds)
    return cred


# --- execution ---------------------------------------------------------------


def execute(request):
    argv = request["argv"]
    started = time.time()
    try:
        proc = subprocess.run(
            argv,
            cwd=request.get("cwd") or "/",
            env=EXEC_ENV,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=EXEC_TIMEOUT,
        )
        rc, out, err = proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired:
        rc, out, err = 124, "", "timeout %ds" % EXEC_TIMEOUT
    except OSError as exc:
        rc, out, err = 127, "", "exec: %s" % exc
    duration = round(time.time() - started, 2)
    return {
        "rc": rc,
        "stdout": out[:MAX_OUTPUT],
        "stderr": err[:MAX_OUTPUT],
        "duration_s": duration,
    }


def finish_request(token, proof, who):
    """Premiere preuve valide : consomme la demande."""
    with _lock:
        request = REQUESTS.get(token)
        if request is None or request.get("done"):
            return False
        request["done"] = True
        request["proof"] = proof
        request["approved_by"] = who
        request["event"].set()
        return True


def touch_id_worker(token, request):
    """Popup Touch ID natif sur le Mac, en parallele du lien et du mot de passe.

    Le broker tourne en root et joint le Mac par SSH : l'agent n'a aucun moyen de
    fabriquer cette preuve. Le helper est un binaire du store Nix (root-owned,
    immuable), donc pas remplacable par un "exit 0" cote Mac.
    """
    text = "Hermes veut executer: %s" % " ".join(request["argv"])
    if request.get("reason"):
        text += " | " + request["reason"]
    payload = "b64:" + base64.b64encode(text[:400].encode()).decode()
    cmd = TOUCHID_SSH + [TOUCHID_REMOTE, payload]
    started = time.time()
    try:
        proc = subprocess.run(
            cmd,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=TOUCHID_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        audit({"event": "touchid_timeout", "id": request["id"], "delta_s": round(time.time() - started, 1)})
        return
    except OSError as exc:
        audit({"event": "touchid_error", "id": request["id"], "error": str(exc)[:120]})
        return
    detail = (proc.stdout or "").strip()[:120]
    if proc.returncode == 0:
        if finish_request(token, "touch-id", "marc@mac"):
            audit(
                {
                    "event": "approved",
                    "id": request["id"],
                    "proof": "touch-id",
                    "cred": "touch-id",
                    "detail": detail,
                    "delta_s": round(time.time() - started, 1),
                }
            )
    else:
        audit({"event": "touchid_refused", "id": request["id"], "rc": proc.returncode, "detail": detail})


# --- page d'approbation ------------------------------------------------------

PAGE = """<!doctype html>
<html lang="fr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Approbation root</title>
<style>
  :root{--bg:#1e1e2e;--ink:#cdd6f4;--mute:#a6adc8;--line:#313244;--acc:#b4befe;--ok:#a6e3a1;--bad:#f38ba8;--warn:#f9e2af}
  *{box-sizing:border-box}
  body{margin:0;padding:24px;background:var(--bg);color:var(--ink);
       font-family:ui-sans-serif,-apple-system,Inter,sans-serif;font-size:15px;line-height:1.5}
  .card{max-width:640px;margin:0 auto;border:1px solid var(--line);border-radius:12px;padding:20px}
  h1{font-size:17px;margin:0 0 4px}
  .sub{color:var(--mute);font-size:12.5px;margin:0 0 16px}
  pre{background:#181825;border:1px solid var(--line);border-radius:8px;padding:12px;
      font-family:ui-monospace,monospace;font-size:13px;white-space:pre-wrap;word-break:break-all;margin:0 0 10px}
  .meta{color:var(--mute);font-size:12px;margin-bottom:16px}
  .row{display:flex;gap:10px;flex-wrap:wrap;margin-bottom:14px}
  button,input[type=password],input[type=text]{font:inherit}
  button{cursor:pointer;border-radius:8px;border:1px solid var(--line);padding:10px 16px;
         background:var(--acc);color:#1e1e2e;font-weight:650}
  button.ghost{background:transparent;color:var(--ink)}
  input{padding:10px 12px;border-radius:8px;border:1px solid var(--line);background:#181825;color:var(--ink);flex:1;min-width:180px}
  .sep{border-top:1px solid var(--line);margin:18px 0;color:var(--mute);font-size:11px;text-transform:uppercase;letter-spacing:.09em}
  .msg{font-size:13px;margin-top:12px;min-height:20px}
  .ok{color:var(--ok)} .bad{color:var(--bad)} .mute{color:var(--mute)}
</style></head><body>
<div class="card">
  <h1>__TITLE__</h1>
  <p class="sub">__SUB__</p>
  <pre id="cmd">__COMMAND__</pre>
  <div class="meta" id="meta">__META__</div>
  <div class="row" id="passkey-row" style="display:none">
    <button id="passkey">Touch ID de ce Mac</button>
    <button class="ghost" id="passkey-other">Autre passkey (telephone, Bitwarden)</button>
  </div>
  <div class="sep">ou mot de passe</div>
  <div class="row">
    <input type="password" id="pw" placeholder="mot de passe de marc sur tower" autocomplete="current-password">
    <button class="ghost" id="submit-pw">Valider</button>
  </div>
  <div class="msg" id="msg"></div>
</div>
<script>
const TOKEN = "__TOKEN__";
const MODE = "__MODE__";
const B64U = {
  enc: buf => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\\+/g,'-').replace(/\\//g,'_').replace(/=+$/,''),
  dec: str => Uint8Array.from(atob(str.replace(/-/g,'+').replace(/_/g,'/')), c => c.charCodeAt(0)),
};
const msg = (text, cls) => { const el = document.getElementById('msg'); el.textContent = text; el.className = 'msg ' + (cls||''); };
async function post(path, body) {
  const res = await fetch(path, {method:'POST', headers:{'content-type':'application/json'}, body: JSON.stringify(body||{})});
  return res.json();
}
async function approve(proof) {
  const out = await post(MODE === 'enroll' ? '/enroll/wa/attest' : '/r/' + TOKEN + '/wa/assert', proof);
  if (out.status === 'ok') { msg('Approuve. Tu peux fermer cette page.', 'ok'); document.getElementById('cmd').textContent=''; return true; }
  msg(out.error || 'refuse', 'bad'); return false;
}
document.getElementById('submit-pw').onclick = async () => {
  const pw = document.getElementById('pw').value;
  if (!pw) return;
  const out = await post(MODE === 'enroll' ? '/enroll/pw' : '/r/' + TOKEN + '/pw', {password: pw});
  if (out.status === 'enrolled') { window.ENROLL = out.enroll; msg('Mot de passe valide. Choisis le Touch ID de ce Mac, ou une autre passkey.', 'ok'); prefetch(true); return; }
  if (out.status === 'ok') { msg('Approuve. Tu peux fermer cette page.', 'ok'); document.getElementById('cmd').textContent=''; return; }
  msg(out.error || 'refuse', 'bad');
};
document.getElementById('pw').addEventListener('keydown', e => { if (e.key === 'Enter') document.getElementById('submit-pw').click(); });

async function fetchOptions(attachment) {
  const path = MODE === 'enroll' ? '/enroll/wa/options' : '/r/' + TOKEN + '/wa/options';
  const out = await post(path, {enroll: window.ENROLL, attachment: attachment});
  if (out.status !== 'ok') throw new Error(out.error || 'options indisponibles');
  return out.publicKey;
}
function hydrate(pk, creation) {
  pk.challenge = B64U.dec(pk.challenge);
  if (creation) {
    pk.user.id = B64U.dec(pk.user.id);
    pk.excludeCredentials = (pk.excludeCredentials||[]).map(c => ({...c, id: B64U.dec(c.id)}));
  } else {
    pk.allowCredentials = (pk.allowCredentials||[]).map(c => ({...c, id: B64U.dec(c.id)}));
  }
  return pk;
}
function report(kind, err) {
  try {
    fetch('/client-log', {method:'POST', headers:{'content-type':'application/json'}, keepalive:true,
      body: JSON.stringify({kind: kind, name: (err && err.name) || '', message: String((err && err.message) || err).slice(0,300), where: location.pathname, ua: navigator.userAgent.slice(0,120)})});
  } catch (e) {}
}
// Les options doivent etre pre-chargees : Chrome exige une activation utilisateur
// au moment exact de create()/get(), et un fetch intercale la consomme.
window.OPTS = {};
async function prefetch(creation) {
  for (const att of ['platform', 'any']) {
    try { window.OPTS[att] = hydrate(await fetchOptions(att === 'any' ? undefined : att), creation); }
    catch (e) { report('prefetch', e); }
  }
  if (!window.OPTS.platform) msg('Aucun authentificateur de la machine disponible, utilise l autre bouton.', 'bad');
}
async function doAssert(att) {
  if (att === 'platform' && window.UV === 'false') {
    msg('Cet onglet ne peut pas faire Touch ID: aucun authentificateur de plateforme dans ce navigateur. Ouvre ce lien dans Chrome ou Safari.', 'bad');
    report('assert-click', {name: att, message: 'uvpaa false: refus local, pas de popup possible'});
    return;
  }
  report('assert-click', {name: att, message: (window.OPTS[att] ? 'options pre-chargees' : 'pas d options')});
  let pk = window.OPTS[att];
  if (!pk) { try { pk = hydrate(await fetchOptions(att === 'any' ? undefined : att), false); } catch (e) { msg(e.message, 'bad'); report('assert', e); return; } }
  let cred;
  const stall = setTimeout(() => report('stall', {name: att, message: 'create/get sans reponse depuis 30s'}), 30000);
  try { cred = await navigator.credentials.get({publicKey: pk}); }
  catch (e) { clearTimeout(stall); msg('refus navigateur: ' + ((e && e.name) || '') + ' ' + ((e && e.message) || ''), 'bad'); report('assert', e); return; }
  clearTimeout(stall);
  window.OPTS = {};
  await approve({
    id: cred.id,
    clientDataJSON: B64U.enc(cred.response.clientDataJSON),
    authenticatorData: B64U.enc(cred.response.authenticatorData),
    signature: B64U.enc(cred.response.signature),
  });
}
async function doCreate(att) {
  if (!window.ENROLL) { msg('valide ton mot de passe d abord', 'bad'); report('create-click', {name: att, message: 'sans session d enrolement'}); return; }
  report('create-click', {name: att, message: (window.OPTS[att] ? 'options pre-chargees' : 'pas d options')});
  let pk = window.OPTS[att];
  if (!pk) { try { pk = hydrate(await fetchOptions(att === 'any' ? undefined : att), true); } catch (e) { msg(e.message, 'bad'); report('create', e); return; } }
  let cred;
  const stall = setTimeout(() => report('stall', {name: att, message: 'create sans reponse depuis 30s'}), 30000);
  try { cred = await navigator.credentials.create({publicKey: pk}); }
  catch (e) { clearTimeout(stall); msg('creation refusee: ' + ((e && e.name) || '') + ' ' + ((e && e.message) || ''), 'bad'); report('create', e); return; }
  clearTimeout(stall);
  window.OPTS = {};
  const out = await post('/enroll/wa/attest', {
    enroll: window.ENROLL,
    id: cred.id,
    name: att === 'platform' ? 'touch-id' : 'passkey',
    clientDataJSON: B64U.enc(cred.response.clientDataJSON),
    attestationObject: B64U.enc(cred.response.attestationObject),
  });
  if (out.status === 'ok') { msg('Passkey enregistree: ' + out.name + '. Tu peux refaire la meme chose pour un autre appareil.', 'ok'); prefetch(true); }
  else { msg(out.error || 'refuse', 'bad'); report('attest-http', out); }
}
document.getElementById('passkey-row').style.display = 'flex';
window.UV = 'inconnu';
report('load', {name: MODE, message: 'uvpaa en cours'});
if (window.PublicKeyCredential && PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable) {
  PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()
    .then(v => { window.UV = String(v); report('uvpaa', {name: String(v), message: ''}); if (!v) msg('Ce navigateur ne propose pas de passkey de plateforme (Touch ID). Ouvre cette page dans Chrome ou Safari.', 'bad'); })
    .catch(e => { window.UV = 'erreur'; report('uvpaa', e); });
} else { window.UV = 'absent'; report('uvpaa', {name: 'absent', message: 'API WebAuthn indisponible'}); }
if (MODE !== 'enroll') {
  document.getElementById('passkey').onclick = () => doAssert('platform');
  document.getElementById('passkey-other').onclick = () => doAssert('any');
  prefetch(false);
} else {
  document.getElementById('passkey').onclick = () => doCreate('platform');
  document.getElementById('passkey-other').onclick = () => doCreate('any');
}
</script>
</body></html>
"""


def render_page(title, subtitle, command, meta, token="", mode="approve"):
    return (
        PAGE.replace("__TITLE__", title)
        .replace("__SUB__", subtitle)
        .replace("__COMMAND__", command)
        .replace("__META__", meta)
        .replace("__TOKEN__", token)
        .replace("__MODE__", mode)
    )


class Handler(BaseHTTPRequestHandler):
    server_version = "hermes-broker"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # journal compact, sans bruit par requete
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    # --- helpers ---
    def send(self, code, body, content_type="application/json"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body)
        raw = b"" if code == 204 else (body.encode() if isinstance(body, str) else body)
        self.send_response(code)
        if raw:
            self.send_header("content-type", content_type)
        self.send_header("content-length", str(len(raw)))
        self.send_header("cache-control", "no-store")
        self.send_header("referrer-policy", "no-referrer")
        self.end_headers()
        if not raw:
            return
        try:
            self.wfile.write(raw)
        except (BrokenPipeError, ConnectionResetError):
            # le navigateur a ferme l'onglet : rien a signaler
            self.close_connection = True

    def read_json(self):
        length = int(self.headers.get("content-length") or 0)
        if not length:
            return {}
        return json.loads(self.rfile.read(length).decode() or "{}")

    # --- routes ---
    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/healthz"):
            return self.send(200, {"status": "up", "pending": len(REQUESTS)})
        if path == "/enroll":
            return self.send(
                200,
                render_page(
                    "Enroler une passkey",
                    "Valide une fois avec ton mot de passe, puis enregistre l'empreinte.",
                    "Aucune commande (enrolement)",
                    "Les passkeys enregistrees servent ensuite a approuver n'importe quelle demande.",
                    mode="enroll",
                ),
                "text/html; charset=utf-8",
            )
        if path.startswith("/r/"):
            token = path[3:].strip("/")
            with _lock:
                request = REQUESTS.get(token)
            if request is None or request.get("done"):
                return self.send(404, {"status": "unknown", "error": "demande inconnue ou deja traitee"})
            command = " ".join(request["argv"])
            meta = "cwd %s · expire %+ds · demande %s" % (
                request.get("cwd") or "/",
                request["exp"] - now(),
                request["created_human"],
            )
            return self.send(
                200,
                render_page(
                    "Hermes demande root",
                    request.get("reason") or "Aucune raison fournie.",
                    command,
                    meta,
                    token=token,
                ),
                "text/html; charset=utf-8",
            )
        return self.send(404, {"status": "error", "error": "inconnu"})

    def do_POST(self):
        path = self.path.split("?")[0]
        try:
            body = self.read_json()
        except ValueError:
            return self.send(400, {"status": "error", "error": "json invalide"})

        # Journal des erreurs cote navigateur : sans ca, un refus WebAuthn cote
        # client (activation utilisateur consommee, authentificateur absent,
        # annulation) ne laisse AUCUNE trace serveur et on diagnostique a
        # l'aveugle. Taille bornee, contenu tronque.
        if path == "/client-log":
            print(
                "client-log %s %s %r %r ua=%r"
                % (
                    str(body.get("kind"))[:20],
                    str(body.get("name"))[:40],
                    str(body.get("message"))[:200],
                    str(body.get("where"))[:40],
                    str(body.get("ua"))[:90],
                ),
                flush=True,
            )
            return self.send(204, {})

        if path.startswith("/r/") and path.endswith("/pw"):
            token = path[3:-3].strip("/")
            return self.handle_password(token, body)

        if path.startswith("/r/") and path.endswith("/wa/options"):
            token = path[3:-11].strip("/")
            return self.handle_assertion_options(token, body)

        if path.startswith("/r/") and path.endswith("/wa/assert"):
            token = path[3:-10].strip("/")
            return self.handle_assertion(token, body, local=False)

        if path == "/enroll/pw":
            return self.handle_enroll_password(body)

        if path == "/enroll/wa/options":
            return self.handle_enroll_options(body)

        if path == "/enroll/wa/attest":
            return self.handle_attestation(body)

        return self.send(404, {"status": "error", "error": "inconnu"})

    # --- canaux ---
    def handle_password(self, token, body):
        with _lock:
            request = REQUESTS.get(token)
            if request is None or request.get("done"):
                return self.send(404, {"status": "error", "error": "demande inconnue"})
            request["attempts"] += 1
            if request["attempts"] > MAX_ATTEMPTS:
                return self.send(429, {"status": "error", "error": "trop de tentatives, demande abandonnee"})
        password = body.get("password") or ""
        if not password:
            return self.send(400, {"status": "error", "error": "mot de passe vide"})
        if not check_password(password):
            audit({"event": "pw_fail", "id": request["id"], "src": self.client_address[0]})
            return self.send(403, {"status": "error", "error": "mot de passe refuse"})
        if not finish_request(token, "password", "marc@pam"):
            return self.send(409, {"status": "error", "error": "deja approuvee par un autre canal"})
        audit({"event": "approved", "id": request["id"], "proof": "password"})
        return self.send(200, {"status": "ok", "proof": "password"})

    def handle_assertion_options(self, token, body):
        with _lock:
            request = REQUESTS.get(token)
            if request is None or request.get("done"):
                return self.send(404, {"status": "error", "error": "demande inconnue"})
            challenge = secrets.token_bytes(32)
            store = request.setdefault("challenges", {})
            prune_challenges(store)
            store[b64u_encode(challenge)] = now() + TTL
        creds = load_creds()
        if not creds:
            return self.send(409, {"status": "error", "error": "aucune passkey enregistree: ouvre /enroll"})
        public_key = {
            "challenge": b64u_encode(challenge),
            "rpId": RP_ID,
            "timeout": 120000,
            "userVerification": "required",
            "allowCredentials": [{"type": "public-key", "id": c["id"]} for c in creds],
        }
        attachment = requested_attachment(body)
        if attachment:
            public_key["authenticatorAttachment"] = attachment
        return self.send(200, {"status": "ok", "publicKey": public_key})

    def handle_assertion(self, token, body, local=False):
        with _lock:
            request = REQUESTS.get(token)
            if request is None or request.get("done"):
                return self.send(404, {"status": "error", "error": "demande inconnue"})
            request["attempts"] += 1
            over = request["attempts"] > MAX_ATTEMPTS
        if over:
            return self.send(429, {"status": "error", "error": "trop de tentatives"})
        try:
            client_data_raw = b64u_decode(body["clientDataJSON"])
            challenge_b64 = client_data_challenge(client_data_raw)
            with _lock:
                store = request.setdefault("challenges", {})
                prune_challenges(store)
                if challenge_b64 not in store:
                    raise ValueError("challenge inconnu ou expire")
            cred = webauthn_assert(
                b64u_decode(challenge_b64),
                body.get("id", ""),
                client_data_raw,
                b64u_decode(body["authenticatorData"]),
                b64u_decode(body["signature"]),
            )
        except (ValueError, KeyError) as exc:
            audit({"event": "passkey_fail", "id": request["id"], "reason": str(exc)[:120]})
            return self.send(403, {"status": "error", "error": "passkey refusee: %s" % exc})
        with _lock:
            request.get("challenges", {}).pop(challenge_b64, None)
        if not finish_request(token, "passkey", cred["name"]):
            return self.send(409, {"status": "error", "error": "deja approuvee"})
        audit({"event": "approved", "id": request["id"], "proof": "passkey", "cred": cred["name"], "aaguid": cred["aaguid"]})
        return self.send(200, {"status": "ok", "proof": "passkey", "cred": cred["name"]})

    def handle_enroll_password(self, body):
        password = body.get("password") or ""
        if not check_password(password):
            audit({"event": "enroll_pw_fail", "src": self.client_address[0]})
            return self.send(403, {"status": "error", "error": "mot de passe refuse"})
        token = secrets.token_urlsafe(18)
        with _lock:
            ENROLLMENTS[token] = {"exp": now() + 600, "challenges": {}}
        audit({"event": "enroll_session_opened", "src": self.client_address[0]})
        return self.send(200, {"status": "enrolled", "enroll": token})

    def handle_enroll_options(self, body):
        token = body.get("enroll") or ""
        challenge = secrets.token_bytes(32)
        with _lock:
            session = ENROLLMENTS.get(token)
            if not session or session["exp"] < now():
                return self.send(403, {"status": "error", "error": "session d'enrolement expiree"})
            session["exp"] = now() + 600
            prune_challenges(session["challenges"])
            session["challenges"][b64u_encode(challenge)] = now() + 600
        creds = load_creds()
        selection = {
            "userVerification": "required",
            "residentKey": "discouraged",
        }
        attachment = requested_attachment(body)
        if attachment:
            selection["authenticatorAttachment"] = attachment
        return self.send(
            200,
            {
                "status": "ok",
                "publicKey": {
                    "challenge": b64u_encode(challenge),
                    "rp": {"id": RP_ID, "name": "hermes-broker"},
                    "user": {
                        "id": b64u_encode(hashlib.sha256(b"marc").digest()[:16]),
                        "name": "marc",
                        "displayName": "Marc",
                    },
                    "pubKeyCredParams": [{"type": "public-key", "alg": -7}],
                    "timeout": 120000,
                    "attestation": "none",
                    "authenticatorSelection": selection,
                    "excludeCredentials": [{"type": "public-key", "id": c["id"]} for c in creds],
                },
            },
        )

    def handle_attestation(self, body):
        token = body.get("enroll") or ""
        try:
            client_data_raw = b64u_decode(body["clientDataJSON"])
            challenge_b64 = client_data_challenge(client_data_raw)
        except (ValueError, KeyError) as exc:
            return self.send(400, {"status": "error", "error": "clientDataJSON invalide: %s" % exc})
        with _lock:
            session = ENROLLMENTS.get(token)
            if not session or session["exp"] < now():
                return self.send(403, {"status": "error", "error": "session d'enrolement expiree"})
            prune_challenges(session["challenges"])
            if challenge_b64 not in session["challenges"]:
                return self.send(403, {"status": "error", "error": "challenge inconnu ou expire, recharge la page"})
        try:
            cred = webauthn_register(
                b64u_decode(challenge_b64),
                client_data_raw,
                b64u_decode(body["attestationObject"]),
                body.get("name", "passkey"),
            )
        except (ValueError, KeyError) as exc:
            audit({"event": "attest_fail", "src": self.client_address[0], "reason": str(exc)[:160]})
            return self.send(403, {"status": "error", "error": "attestation refusee: %s" % exc})
        with _lock:
            session["challenges"].pop(challenge_b64, None)
        audit({"event": "credential_enrolled", "name": cred["name"], "aaguid": cred["aaguid"]})
        return self.send(200, {"status": "ok", "name": cred["name"]})


# --- socket local (cote agent) ----------------------------------------------


def serve_client(conn, peercred=(-1, -1, -1)):
    conn.settimeout(TTL + 60)
    buffer = b""
    try:
        while b"\n" not in buffer:
            chunk = conn.recv(65536)
            if not chunk:
                return
            buffer += chunk
        payload = json.loads(buffer.split(b"\n")[0].decode())
        argv = payload.get("argv") or []
        if not isinstance(argv, list) or not argv or not all(isinstance(a, str) for a in argv):
            conn.sendall(b'{"status":"error","error":"argv invalide"}\n')
            return
        token = secrets.token_urlsafe(24)
        request = {
            "id": secrets.token_hex(3),
            "argv": argv,
            "cwd": payload.get("cwd") or "/",
            "reason": (payload.get("reason") or "").strip()[:400],
            "exp": now() + TTL,
            "created_human": time.strftime("%H:%M:%S", time.localtime()),
            "attempts": 0,
            "event": threading.Event(),
            "done": False,
        }
        with _lock:
            REQUESTS[token] = request
        url = "%s/r/%s" % (ORIGIN, token)
        print(
            "demande %s de uid %d: %s (approbation: %s)"
            % (request["id"], peercred[0], " ".join(argv), url),
            flush=True,
        )
        conn.sendall(
            (
                json.dumps(
                    {
                        "status": "pending",
                        "id": request["id"],
                        "url": url,
                        "expires_in": TTL,
                        "touch_id": bool(TOUCHID_SSH),
                    }
                )
                + "\n"
            ).encode()
        )
        if TOUCHID_SSH:
            threading.Thread(target=touch_id_worker, args=(token, request), daemon=True).start()
        approved = request["event"].wait(TTL)
        with _lock:
            REQUESTS.pop(token, None)
        if not approved:
            audit({"event": "expired", "id": request["id"], "argv": argv})
            conn.sendall(b'{"status":"expired","error":"aucune preuve dans le delai"}\n')
            return
        result = execute(request)
        entry = {
            "event": "executed",
            "id": request["id"],
            "argv": argv,
            "cwd": request["cwd"],
            "reason": request["reason"],
            "proof": request["proof"],
            "by": request["approved_by"],
            "rc": result["rc"],
            "duration_s": result["duration_s"],
        }
        audit(entry)
        conn.sendall(
            (
                json.dumps(
                    {
                        "status": "executed",
                        "id": request["id"],
                        "proof": request["proof"],
                        **result,
                    }
                )
                + "\n"
            ).encode()
        )
    except Exception as exc:  # noqa: BLE001
        try:
            conn.sendall((json.dumps({"status": "error", "error": repr(exc)[:200]}) + "\n").encode())
        except OSError:
            pass
    finally:
        conn.close()


def unix_server():
    if os.path.exists(SOCK_PATH):
        os.unlink(SOCK_PATH)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(SOCK_PATH)
    os.chmod(SOCK_PATH, 0o660)
    try:
        import grp

        os.chown(SOCK_PATH, 0, grp.getgrnam(CALLER_GROUP).gr_gid)
    except (KeyError, PermissionError):
        pass
    server.listen(16)
    print("broker: socket %s pret" % SOCK_PATH, flush=True)
    while True:
        conn, _ = server.accept()
        # authentification du pair par le noyau : uid/gid du processus appelant
        try:
            import struct

            raw = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
            pid, uid, gid = struct.unpack("3i", raw)
            peercred = (uid, gid, pid)
        except OSError:
            peercred = (-1, -1, -1)
        if peercred[0] not in (0, os.stat("/var/lib/hermes").st_uid):
            try:
                conn.sendall(b'{"status":"error","error":"uid non autorise"}\n')
                conn.close()
            except OSError:
                pass
            continue
        threading.Thread(target=serve_client, args=(conn, peercred), daemon=True).start()


def http_server():
    httpd = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print("broker: http 127.0.0.1:%d (rp=%s)" % (PORT, RP_ID), flush=True)
    httpd.serve_forever()


# --- client CLI --------------------------------------------------------------


def client_main(argv):
    if "--" not in argv:
        sys.exit("usage: hermes-request --reason '...' [--cwd DIR] -- cmd arg...")
    split = argv.index("--")
    options, command = argv[:split], argv[split + 1 :]
    reason, cwd = "", None
    index = 0
    while index < len(options):
        if options[index] == "--reason":
            reason = options[index + 1]
            index += 2
        elif options[index] == "--cwd":
            cwd = options[index + 1]
            index += 2
        else:
            sys.exit("option inconnue: %s" % options[index])
    if not command:
        sys.exit("aucune commande")
    payload = {"argv": command, "cwd": cwd or os.getcwd(), "reason": reason}
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(TTL + 90)
    conn.connect(SOCK_PATH)
    conn.sendall((json.dumps(payload) + "\n").encode())
    chunks = []
    while True:
        chunk = conn.recv(65536)
        if not chunk:
            break
        chunks.append(chunk)
        if b"\n" in chunk:
            line, _, rest = b"".join(chunks).partition(b"\n")
            try:
                message = json.loads(line)
            except ValueError:
                sys.stderr.write(line.decode(errors="replace") + "\n")
                return 1
            if message.get("status") == "pending":
                if message.get("touch_id"):
                    sys.stderr.write("popup: Touch ID demande sur le Mac de marc (repli: %s)\n" % message["url"])
                else:
                    sys.stderr.write("approbation: %s\n" % message["url"])
                chunks = [rest] if rest else []
                continue
            if message.get("status") == "executed":
                sys.stdout.write(message.get("stdout") or "")
                sys.stderr.write(message.get("stderr") or "")
                return message.get("rc", 1)
            sys.stderr.write(json.dumps(message, ensure_ascii=False) + "\n")
            return 1
    return 1


def main():
    os.makedirs(STATE_DIR, exist_ok=True)
    runtime_dir = os.path.dirname(SOCK_PATH)
    os.makedirs(runtime_dir, exist_ok=True)
    # le socket vit dans un dossier que l'appelant doit pouvoir traverser
    try:
        import grp

        gid = grp.getgrnam(CALLER_GROUP).gr_gid
        os.chown(runtime_dir, 0, gid)
        os.chmod(runtime_dir, 0o750)
    except (KeyError, PermissionError):
        pass
    threading.Thread(target=http_server, daemon=True).start()
    unix_server()


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "client":
        sys.exit(client_main(sys.argv[2:]))
    main()
