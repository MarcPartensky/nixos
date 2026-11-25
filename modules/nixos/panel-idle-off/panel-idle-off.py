#!/usr/bin/env python3
"""Turn the internal panel off after a period without input, and back on at the
first input event. The machine is never suspended.

Why evdev instead of a compositor idle daemon: Steam Gaming Mode runs gamescope,
which implements no idle protocol at all (no ext-idle-notify-v1, no idle-inhibit,
no org.kde.kwin.idle) and holds the DRM master, so swayidle/wlopm do nothing there.
Reading /dev/input/event* directly also catches the gamepad, since Steam Input
re-emits the controller on evdev.

Runs as root: bl_power lives under /sys/class/backlight/<name>/.
"""

import glob
import os
import select
import signal
import sys
import time

IDLE_SECONDS = float(os.environ.get("IDLE_SECONDS", "300"))
BACKLIGHT = os.environ.get("BACKLIGHT", "amdgpu_bl0")
INPUT_GLOB = os.environ.get("INPUT_GLOB", "/dev/input/event*")
RESCAN_SECONDS = 10.0

SYSFS = os.path.join("/sys/class/backlight", BACKLIGHT)
BL_POWER = os.path.join(SYSFS, "bl_power")
BRIGHTNESS = os.path.join(SYSFS, "brightness")
MAX_BRIGHTNESS = os.path.join(SYSFS, "max_brightness")


def log(message):
    print(f"panel-idle-off: {message}", flush=True)


def read_int(path):
    try:
        with open(path) as handle:
            return int(handle.read().strip())
    except OSError:
        return None


def write_value(path, value):
    try:
        with open(path, "w") as handle:
            handle.write(str(value))
        return True
    except OSError as error:
        log(f"cannot write {path}: {error}")
        return False


class Panel:
    """Internal panel backlight: off means the panel is dark, the machine runs."""

    def __init__(self):
        self.method = None
        self.saved_brightness = None

    def off(self):
        if self.method:
            return
        self.saved_brightness = read_int(BRIGHTNESS)
        # bl_power cuts the backlight power; brightness 0 is the fallback for
        # panels whose bl_power is not writable.
        if write_value(BL_POWER, 1):
            self.method = "bl_power"
        elif write_value(BRIGHTNESS, 0):
            self.method = "brightness"
        else:
            return
        log(f"panel off via {self.method} (brightness was {self.saved_brightness})")

    def on(self):
        if not self.method:
            return
        if self.method == "bl_power":
            write_value(BL_POWER, 0)
        else:
            target = self.saved_brightness
            if not target:
                # Blanked right before a shutdown: systemd-backlight restored the
                # saved 0, so fall back to half brightness instead of staying black.
                target = (read_int(MAX_BRIGHTNESS) or 0) // 2
            write_value(BRIGHTNESS, target)
        log("panel back on")
        self.method = None


class InputWatcher:
    def __init__(self):
        self.fds = {}
        self.scan()

    def scan(self):
        """Open the input devices, including ones plugged in after startup."""
        for path in sorted(glob.glob(INPUT_GLOB)):
            if path in self.fds.values():
                continue
            try:
                self.fds[os.open(path, os.O_RDONLY | os.O_NONBLOCK)] = path
            except OSError as error:
                log(f"cannot open {path}: {error}")
        return len(self.fds)

    def wait(self, timeout):
        """Wait up to timeout; return the device that produced input, or None."""
        try:
            ready, _, _ = select.select(list(self.fds), [], [], timeout)
        except OSError:
            ready = []
        active = None
        for fd in ready:
            try:
                # Only the fact that something happened matters, the events
                # themselves are not interpreted.
                os.read(fd, 4096)
            except OSError:
                pass
            if active is None:
                active = self.fds.get(fd)
        return active


def main():
    if not os.path.isdir(SYSFS):
        log(f"backlight {SYSFS} not found, nothing to do")
        return 1

    panel = Panel()
    watcher = InputWatcher()
    if not watcher.fds:
        log("no readable input device: refusing to blank anything")
        return 1

    # A previous run may have been killed with SIGKILL while the panel was off.
    write_value(BL_POWER, 0)

    def restore(_signum, _frame):
        panel.on()
        sys.exit(0)

    signal.signal(signal.SIGTERM, restore)
    signal.signal(signal.SIGINT, restore)

    log(
        f"watching {len(watcher.fds)} input devices, "
        f"blanking after {IDLE_SECONDS:.0f}s idle, backlight {BACKLIGHT}"
    )
    last_activity = time.monotonic()
    next_scan = last_activity + RESCAN_SECONDS

    while True:
        active = watcher.wait(1.0)
        now = time.monotonic()

        if active is not None:
            if panel.method:
                panel.on()
            last_activity = now
        elif panel.method is None and now - last_activity >= IDLE_SECONDS:
            panel.off()

        if now >= next_scan:
            next_scan = now + RESCAN_SECONDS
            watcher.scan()


if __name__ == "__main__":
    sys.exit(main())
