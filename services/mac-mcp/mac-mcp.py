"""MCP server "mac": drives marc's Mac from tower via ssh.

Serves the Winnie build cycle: machine state (winnie-doctor), repo sync
from tower, repairs (--fix), root Xcode operations (sudo NOPASSWD rule
xcode-select/xcodebuild/xcrun, see sudoers.d/20-hermes-xcode),
iOS simulator runtime (~8 GB, in the background) and tauri builds
(macOS desktop; iOS simulator) launched in the background, logs
viewable via log_tail.

Everything runs over ssh under the marc account; long builds return
immediately and are followed via log_tail. Host chosen on the first call:
alias maclan (LAN) then mac (reverse tunnel via rack).
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

# pgrep patterns: the [x] prevents the pgrep process itself (whose command
# line contains the pattern) from counting itself.
LOGS = {
    "runtime": "[d]ownloadPlatform",
    "ios-init": "[t]auri ios init",
    "ios-dev": "[t]auri ios dev",
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
    raise RuntimeError("Mac unreachable (%s)" % " ; ".join(errors))


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
            "ssh %s failed (rc=%s):\n%s" % (host, r.returncode, out[-2000:])
        )
    return out


def _start(name, cmd):
    log = "/Users/marc/winnie-%s.log" % name
    line = "cd %s && nohup %s >%s 2>&1 </dev/null & echo pid=$!" % (
        REPO, cmd, log)
    out = _ssh(line, timeout=60)
    return "%s launched in the background (%s); follow log_tail('%s').\n%s" % (
        name, log, name, out)


def _dev(cmd):
    return "%s develop -c bash -c %s" % (NIX, shlex.quote(cmd))


@mcp.tool()
def status() -> str:
    """State of the Mac machine for building Winnie.

    winnie-doctor (Xcode, license, iOS SDK, simulator runtime,
    node_modules, API) + revisions of the ~/git/winnie and ~/git/nixos
    repos + reachable ssh host (maclan or mac).
    """
    revs = _ssh(
        "cd %s && git log -1 --format='winnie %%h %%s' ; "
        "cd ~/git/nixos && git log -1 --format='nixos %%h %%s'" % REPO,
        timeout=60,
    )
    doc = _ssh("%s/winnie-doctor ; echo RC=$?" % BIN, timeout=180)
    return "ssh host: %s\n%s\n\n%s" % (_pick_host(), revs, doc)


@mcp.tool()
def sync(delete: bool = False) -> str:
    """Refreshes ~/git/winnie on the Mac from tower (rsync ssh).

    delete=False (default) keeps extra local files;
    delete=True makes a strict mirror of tower.
    """
    arg = " --delete" if delete else ""
    return _ssh("%s/winnie-sync%s" % (BIN, arg), timeout=600)


@mcp.tool()
def doctor_fix() -> str:
    """winnie-doctor --fix: repairs the Mac machine (repo, node_modules,
    Xcode, license, runtime). Root operations go through the deployed
    sudo NOPASSWD rule. Safe to re-run.
    """
    return _ssh("%s/winnie-doctor --fix ; echo RC=$?" % BIN, timeout=1800)


@mcp.tool()
def xcode_fix() -> str:
    """Points xcode-select at /Applications/Xcode.app, accepts the Xcode
    license and installs the first components (the three root operations,
    via sudo). To re-run after any (re)installation or major Xcode
    update; concludes on the state of the SDK.
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
    """Downloads the iOS simulator runtime on the Mac (~8 GB, long) in the
    background; follow with log_tail('runtime'). Useless if status already
    shows it present.
    """
    return _start("runtime",
                  "sudo -n /usr/bin/xcodebuild -downloadPlatform iOS")


@mcp.tool()
def ios_init() -> str:
    """On the Mac: npm ci if needed then tauri ios init (Xcode project +
    pod install) in the winnie devShell. Blocks for a few minutes; no
    effect if app/src-tauri/gen/apple already exists.
    """
    # npm and NOT ./node_modules/.bin/tauri: the CLI copies its own invocation
    # into the "Build Rust Code" phase of the Xcode project. Launched directly it
    # writes "node tauri ios xcode-script ...", which resolves nothing at build
    # time (Cannot find module '.../gen/apple/tauri'); through npm it writes
    # "npm run -- tauri ios xcode-script ...", which works.
    inner = ("cd app && { [ -d node_modules ] || npm ci; }"
             " && { [ -d src-tauri/gen/apple ]"
             " || npm run tauri -- ios init --ci; }")
    return _ssh("cd %s && %s" % (REPO, _dev(inner)), timeout=1500)


@mcp.tool()
def ios_dev(device: str = "") -> str:
    """iOS dev client in live reload on the simulator (tauri ios dev), in the
    background; follow with log_tail('ios-dev').

    This is the iOS equivalent of the Android dev client: the app loads the devUrl of
    app/src-tauri/tauri.ios.conf.json, that is, tower's dev server
    (https://dev.winnie.marcpartensky.com), so an edit of the front on tower
    applies there without a rebuild. empty device = first available iPhone
    simulator (chosen by the winnie-ios wrapper). Prerequisites: simulator
    runtime (runtime_install), gen/apple (ios_init) and the winnie-dev unit
    active on tower.
    """
    arg = " " + shlex.quote(device) if device else ""
    return _start("ios-dev", "%s/winnie-ios%s" % (BIN, arg))

@mcp.tool()
def ios_build_sim() -> str:
    """iOS build for the simulator (no Apple account required), in the
    background; follow with log_tail('ios-build'). Prerequisites: simulator
    runtime (runtime_install) and gen/apple (ios_init).
    """
    inner = ("cd app && ./node_modules/.bin/tauri ios build"
             " --target aarch64-sim; echo BUILD_EXIT=$?")
    return _start("ios-build", _dev(inner))


@mcp.tool()
def macos_build() -> str:
    """macOS desktop build (.app + .dmg, Command Line Tools are enough), in the
    background; follow with log_tail('macos-build').
    """
    inner = ("cd app && ./node_modules/.bin/tauri build"
             "; echo BUILD_EXIT=$?")
    return _start("macos-build", _dev(inner))


@mcp.tool()
def log_tail(name: str, lines: int = 40) -> str:
    """Last lines of the log of a background task; name among
    runtime, ios-build, macos-build. Also says whether the task is still running.
    """
    if name not in LOGS:
        raise RuntimeError("unknown name: %s (expected: %s)"
                           % (name, ", ".join(sorted(LOGS))))
    cmd = ("tail -n %d /Users/marc/winnie-%s.log 2>/dev/null"
           " ; echo --- ; pgrep -fl %s | head -5 || true")
    return _ssh(cmd % (lines, name, shlex.quote(LOGS[name])), timeout=60)


if __name__ == "__main__":
    mcp.run()
