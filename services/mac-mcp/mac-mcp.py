"""Serveur MCP "mac" : pilote le Mac de marc depuis tower via ssh.

Sert le cycle de build de Winnie : etat du poste (winnie-doctor), sync du
depot depuis tower, reparations (--fix), operations root Xcode (regle sudo
NOPASSWD xcode-select/xcodebuild/xcrun, voir sudoers.d/20-hermes-xcode),
runtime du simulateur iOS (~8 Go, en arriere-plan) et builds tauri
(macOS desktop ; iOS simulateur) lances en arriere-plan, journaux
consultables par log_tail.

Tout tourne en ssh sous le compte marc ; les longs builds rendent la main
tout de suite et se suivent par log_tail. Hote choisi au premier appel :
alias maclan (LAN) puis mac (tunnel inverse par rack).
"""

import os
import shlex
import subprocess

try:
    from mcp.server import MCPServer  # mcp >= 2
except ImportError:
    from mcp.server.fastmcp import FastMCP as MCPServer  # mcp 1.x

HOSTS = os.environ.get("WINNIE_MAC_HOSTS", "maclan mac").split()
REPO = os.environ.get("WINNIE_MAC_REPO", "/Users/marc/git/winnie")
BIN = "/etc/profiles/per-user/marc/bin"
PATH_PREFIX = 'export PATH="/run/current-system/sw/bin:%s:$PATH";' % BIN
NIX = "nix --extra-experimental-features 'nix-command flakes'"

# Motifs pgrep : le [x] empeche le process du pgrep (dont la ligne de
# commande contient le motif) de se compter lui-meme.
LOGS = {
    "runtime": "[d]ownloadPlatform",
    "ios-build": "[t]auri ios build",
    "macos-build": "[t]auri build",
}

mcp = MCPServer("mac")
_host = None


def _pick_host():
    global _host
    if _host is not None:
        return _host
    errors = []
    for h in HOSTS:
        try:
            r = subprocess.run(
                ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6",
                 "-o", "StrictHostKeyChecking=accept-new", h, "true"],
                capture_output=True, text=True, timeout=20,
            )
        except subprocess.TimeoutExpired:
            errors.append("%s: timeout" % h)
            continue
        if r.returncode == 0:
            _host = h
            return h
        lines = (r.stderr or "").strip().splitlines()
        errors.append("%s: %s" % (h, lines[-1] if lines else "rc!=0"))
    raise RuntimeError("Mac injoignable (%s)" % " ; ".join(errors))


def _ssh(cmd, timeout=900):
    host = _pick_host()
    r = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", host,
         "bash -c " + shlex.quote(PATH_PREFIX + " " + cmd)],
        capture_output=True, text=True, timeout=timeout,
    )
    out = ((r.stdout or "") + (r.stderr or "")).strip()
    if r.returncode != 0:
        raise RuntimeError(
            "ssh %s a echoue (rc=%s) :\n%s" % (host, r.returncode, out[-2000:])
        )
    return out


def _start(name, cmd):
    log = "/Users/marc/winnie-%s.log" % name
    line = "cd %s && nohup %s >%s 2>&1 </dev/null & echo pid=$!" % (
        REPO, cmd, log)
    out = _ssh(line, timeout=60)
    return "%s lance en arriere-plan (%s) ; suivi log_tail('%s').\n%s" % (
        name, log, name, out)


def _dev(cmd):
    return "%s develop -c bash -c %s" % (NIX, shlex.quote(cmd))


@mcp.tool()
def status() -> str:
    """Etat du poste Mac pour builder Winnie.

    winnie-doctor (Xcode, licence, SDK iOS, runtime du simulateur,
    node_modules, API) + revisions des depots ~/git/winnie et ~/git/nixos
    + hote ssh joignable (maclan ou mac).
    """
    revs = _ssh(
        "cd %s && git log -1 --format='winnie %%h %%s' ; "
        "cd ~/git/nixos && git log -1 --format='nixos %%h %%s'" % REPO,
        timeout=60,
    )
    doc = _ssh("%s/winnie-doctor ; echo RC=$?" % BIN, timeout=180)
    return "hote ssh : %s\n%s\n\n%s" % (_pick_host(), revs, doc)


@mcp.tool()
def sync(delete: bool = False) -> str:
    """Rafraichit ~/git/winnie sur le Mac depuis tower (rsync ssh).

    delete=False (defaut) garde les fichiers locaux en trop ;
    delete=True fait un miroir strict de tower.
    """
    arg = " --delete" if delete else ""
    return _ssh("%s/winnie-sync%s" % (BIN, arg), timeout=600)


@mcp.tool()
def doctor_fix() -> str:
    """winnie-doctor --fix : repare le poste Mac (depot, node_modules,
    Xcode, licence, runtime). Les operations root passent par la regle
    sudo NOPASSWD deployee. Relancable sans risque.
    """
    return _ssh("%s/winnie-doctor --fix ; echo RC=$?" % BIN, timeout=1800)


@mcp.tool()
def xcode_fix() -> str:
    """Pointe xcode-select sur /Applications/Xcode.app, accepte la licence
    Xcode et installe les premiers composants (les trois operations root,
    via sudo). A relancer apres toute (re)installation ou mise a jour
    majeure de Xcode ; conclut sur l'etat du SDK.
    """
    return _ssh(
        "sudo -n /usr/bin/xcode-select -s /Applications/Xcode.app"
        " && sudo -n /usr/bin/xcodebuild -license accept"
        " && sudo -n /usr/bin/xcodebuild -runFirstLaunch"
        " ; /usr/bin/xcode-select -p"
        " ; /usr/bin/xcrun --sdk iphoneos --show-sdk-version",
        timeout=1800,
    )


@mcp.tool()
def runtime_install() -> str:
    """Telecharge le runtime du simulateur iOS sur le Mac (~8 Go, long) en
    arriere-plan ; suivre avec log_tail('runtime'). Inutile si status le
    montre deja present.
    """
    return _start("runtime",
                  "sudo -n /usr/bin/xcodebuild -downloadPlatform iOS")


@mcp.tool()
def ios_init() -> str:
    """Sur le Mac : npm ci si besoin puis tauri ios init (projet Xcode +
    pod install) dans le devShell winnie. Bloque quelques minutes ; sans
    effet si app/src-tauri/gen/apple existe deja.
    """
    inner = ("cd app && { [ -d node_modules ] || npm ci; }"
             " && { [ -d src-tauri/gen/apple ]"
             " || ./node_modules/.bin/tauri ios init; }")
    return _ssh("cd %s && %s" % (REPO, _dev(inner)), timeout=1500)


@mcp.tool()
def ios_build_sim() -> str:
    """Build iOS pour le simulateur (aucun compte Apple requis), en
    arriere-plan ; suivre avec log_tail('ios-build'). Pre-requis : runtime
    du simulateur (runtime_install) et gen/apple (ios_init).
    """
    inner = ("cd app && ./node_modules/.bin/tauri ios build"
             " --target aarch64-sim; echo BUILD_EXIT=$?")
    return _start("ios-build", _dev(inner))


@mcp.tool()
def macos_build() -> str:
    """Build macOS desktop (.app + .dmg, Command Line Tools suffisent), en
    arriere-plan ; suivre avec log_tail('macos-build').
    """
    inner = ("cd app && ./node_modules/.bin/tauri build"
             "; echo BUILD_EXIT=$?")
    return _start("macos-build", _dev(inner))


@mcp.tool()
def log_tail(name: str, lines: int = 40) -> str:
    """Dernieres lignes du journal d'une tache en arriere-plan ; name parmi
    runtime, ios-build, macos-build. Dit aussi si la tache tourne encore.
    """
    if name not in LOGS:
        raise RuntimeError("nom inconnu : %s (attendu : %s)"
                           % (name, ", ".join(sorted(LOGS))))
    cmd = ("tail -n %d /Users/marc/winnie-%s.log 2>/dev/null"
           " ; echo --- ; pgrep -fl %s | head -5 || true")
    return _ssh(cmd % (lines, name, shlex.quote(LOGS[name])), timeout=60)


if __name__ == "__main__":
    mcp.run()
