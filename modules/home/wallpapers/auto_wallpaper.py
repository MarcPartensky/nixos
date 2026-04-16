#!/usr/bin/env python3
"""
Wallpaper manager based on ambient brightness.
Automatically selects wallpaper based on time and weather.
"""
import os
import subprocess
import math
import datetime
import time
import sys
import random
import yaml
import argparse
from pathlib import Path
from typing import Dict, List, Tuple

# --- GLOBAL CONSTANTS ---
SCRIPT_DIR = Path(__file__).parent.resolve()
HOME = Path.home()
BASE_DIR = HOME / "git/wallpapers"
CONFIG_FILE = BASE_DIR / "config.yml"
CACHE_FILE = BASE_DIR / ".brightness_cache.yml"

# Supported image extensions
IMAGE_EXTENSIONS = {'.png', '.jpg', '.jpeg', '.webp', '.bmp', '.gif'}


def has_wayland_display() -> bool:
    """Check if a Wayland display is available."""
    return bool(os.environ.get("WAYLAND_DISPLAY"))


def load_config() -> dict:
    """Load configuration from YAML file."""
    if not CONFIG_FILE.exists():
        print(f"Error: config file not found: {CONFIG_FILE}", file=sys.stderr)
        sys.exit(1)

    try:
        with open(CONFIG_FILE, 'r') as f:
            config = yaml.safe_load(f)
            return config if config else {}
    except yaml.YAMLError as e:
        print(f"Error parsing YAML: {e}", file=sys.stderr)
        sys.exit(1)


def get_image_brightness(filepath: Path) -> float:
    """
    Compute average brightness (0.0 to 1.0) via ImageMagick.
    Falls back to 0.5 on failure.
    """
    for cmd_base in [["magick"], ["convert"]]:
        try:
            cmd = cmd_base + [str(filepath), "-colorspace", "Gray", "-format", "%[fx:mean]", "info:"]
            result = subprocess.check_output(
                cmd,
                stderr=subprocess.PIPE,
                timeout=10
            ).decode("utf-8").strip()
            brightness = float(result)
            if 0.0 <= brightness <= 1.0:
                return brightness
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError):
            continue

    print(f"Error reading {filepath.name}, using default value", file=sys.stderr)
    return 0.5


def load_cache() -> Dict[str, float]:
    """Load brightness cache from YAML file."""
    if not CACHE_FILE.exists():
        return {}

    try:
        with open(CACHE_FILE, 'r') as f:
            cache = yaml.safe_load(f)
            return cache if isinstance(cache, dict) else {}
    except (yaml.YAMLError, IOError):
        return {}


def save_cache(cache: Dict[str, float]) -> None:
    """Save brightness cache to YAML file."""
    try:
        with open(CACHE_FILE, 'w') as f:
            yaml.dump(cache, f, default_flow_style=False, allow_unicode=True)
    except IOError as e:
        print(f"Error saving cache: {e}", file=sys.stderr)


def get_weather_modifier(weather_factors: Dict[str, float]) -> Tuple[float, str]:
    """
    Fetch weather and return a brightness multiplier and description.
    """
    try:
        cmd = ["curl", "-s", "-m", "5", "wttr.in/?format=j1"]
        result = subprocess.check_output(cmd, timeout=6).decode("utf-8")
        import json
        data = json.loads(result)
        condition = data['current_condition'][0]['weatherDesc'][0]['value']

        for key, factor in weather_factors.items():
            if key.lower() in condition.lower():
                return factor, condition

        return 1.0, condition
    except Exception as e:
        print(f"Weather unavailable ({e}), assuming clear sky")
        return 1.0, "Clear (fallback)"


def get_time_target() -> float:
    """
    Return a brightness target based on time (cosinusoidal).
    1.0 at 13:00 (solar noon), 0.0 at 01:00.
    """
    now = datetime.datetime.now()
    hour = now.hour + now.minute / 60.0
    base_brightness = (math.cos((hour - 13) * math.pi / 12) + 1) / 2
    return base_brightness


def init_swww() -> None:
    """Check if swww daemon is running, start it if not."""
    try:
        subprocess.check_call(
            ["swww", "query"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=2
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        print("Starting swww-daemon...")
        subprocess.Popen(
            ["swww-daemon"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )
        time.sleep(1.5)


def find_wallpapers(wall_dir: Path) -> List[Path]:
    """Find all image files in directory."""
    files = []
    for ext in IMAGE_EXTENSIONS:
        files.extend(wall_dir.glob(f"*{ext}"))
        files.extend(wall_dir.glob(f"*{ext.upper()}"))
    return sorted(set(files))


def select_wallpaper(
    files_with_brightness: List[Tuple[Path, float]],
    target: float,
    pool_size: int
) -> Tuple[Path, float]:
    """
    Select a wallpaper from the closest matches to the target brightness.
    """
    if not files_with_brightness:
        raise ValueError("No images available")

    sorted_files = sorted(
        files_with_brightness,
        key=lambda x: abs(x[1] - target)
    )

    candidates = sorted_files[:max(1, pool_size)]
    selected = random.choice(candidates)

    return selected


def apply_wallpaper(image_path: Path, swww_config: dict) -> None:
    """Apply wallpaper via swww."""
    cmd = [
        "swww", "img", str(image_path),
        "--transition-type", str(swww_config.get("transition_type", "simple")),
        "--transition-pos", str(swww_config.get("transition_pos", "center")),
        "--transition-fps", str(swww_config.get("transition_fps", "60")),
        "--transition-duration", str(swww_config.get("transition_duration", "2"))
    ]

    try:
        subprocess.run(cmd, check=True, timeout=10)
    except subprocess.CalledProcessError as e:
        print(f"Error applying wallpaper: {e}", file=sys.stderr)
        sys.exit(0)  # clean exit, no display = not a fatal error


def rebuild_cache(wall_dir: Path, force: bool = False) -> None:
    """Rebuild brightness cache."""
    print("Rebuilding brightness cache...")
    files = find_wallpapers(wall_dir)

    if not files:
        print(f"No images found in {wall_dir}")
        return

    cache = {} if force else load_cache()
    updated = 0

    for filepath in files:
        name = filepath.name
        if force or name not in cache:
            print(f"Analyzing: {name}")
            cache[name] = get_image_brightness(filepath)
            updated += 1

    save_cache(cache)
    print(f"Cache updated: {updated} images analyzed, {len(cache)} total")


def main():
    parser = argparse.ArgumentParser(
        description="Adaptive wallpaper manager based on brightness"
    )
    parser.add_argument(
        '--rebuild-cache',
        action='store_true',
        help="Rebuild brightness cache for all images"
    )
    parser.add_argument(
        '--force-change',
        action='store_true',
        help="Force wallpaper change immediately"
    )
    parser.add_argument(
        '--show-target',
        action='store_true',
        help="Print current brightness target without changing wallpaper"
    )

    args = parser.parse_args()

    # 1. Check Wayland display
    if not has_wayland_display():
        print("No WAYLAND_DISPLAY, nothing to do.", file=sys.stderr)
        sys.exit(0)

    # 2. Load config
    config = load_config()
    wall_dir = BASE_DIR
    pool_size = config.get('variability_pool', 10)

    if not wall_dir.exists():
        print(f"Error: directory {wall_dir} not found", file=sys.stderr)
        sys.exit(1)

    # 3. Special commands
    if args.rebuild_cache:
        rebuild_cache(wall_dir, force=True)
        return

    # 4. Compute target
    time_target = get_time_target()
    weather_mod, weather_desc = get_weather_modifier(
        config.get('weather_factors', {})
    )
    final_target = max(0.0, min(1.0, time_target * weather_mod))

    print(f"Time: {datetime.datetime.now().strftime('%H:%M')}")
    print(f"Time brightness: {time_target:.2f}")
    print(f"Weather: {weather_desc} (x{weather_mod})")
    print(f"Final target: {final_target:.2f}")

    if args.show_target:
        return

    # 5. Load images and cache
    files = find_wallpapers(wall_dir)
    if not files:
        print(f"No images found in {wall_dir}")
        sys.exit(1)

    cache = load_cache()
    updated_cache = False
    valid_files = []

    for filepath in files:
        name = filepath.name
        if name not in cache:
            print(f"New image detected: {name}")
            cache[name] = get_image_brightness(filepath)
            updated_cache = True
        valid_files.append((filepath, cache[name]))

    if updated_cache:
        save_cache(cache)

    # 6. Init swww
    init_swww()

    # 7. Select and apply
    try:
        selected_image, brightness = select_wallpaper(
            valid_files,
            final_target,
            pool_size
        )

        print(f"Selection pool: {min(pool_size, len(valid_files))} images")
        print(f"Selected image: {selected_image.name}")
        print(f"Brightness: {brightness:.2f} (delta = {abs(brightness - final_target):.2f})")

        apply_wallpaper(selected_image, config.get('swww', {}))

    except ValueError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
