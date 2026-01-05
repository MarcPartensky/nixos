#!/usr/bin/env python3
"""
Wallpaper manager basé sur la luminosité ambiante
Gère automatiquement la sélection de fond d'écran selon l'heure et la météo
"""
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

# --- CONSTANTES GLOBALES ---
SCRIPT_DIR = Path(__file__).parent.resolve()
HOME = Path.home()
BASE_DIR = HOME / "git/wallpapers"
CONFIG_FILE = BASE_DIR / "config.yml"
CACHE_FILE = BASE_DIR / ".brightness_cache.yml"

# Extensions d'images supportées
IMAGE_EXTENSIONS = {'.png', '.jpg', '.jpeg', '.webp', '.bmp', '.gif'}


def load_config() -> dict:
    """Charge la configuration depuis le fichier YAML."""
    if not CONFIG_FILE.exists():
        print(f"Erreur : Fichier de config introuvable : {CONFIG_FILE}", file=sys.stderr)
        sys.exit(1)
    
    try:
        with open(CONFIG_FILE, 'r') as f:
            config = yaml.safe_load(f)
            return config if config else {}
    except yaml.YAMLError as e:
        print(f"Erreur parsing YAML : {e}", file=sys.stderr)
        sys.exit(1)


def get_image_brightness(filepath: Path) -> float:
    """
    Calcule la luminosité moyenne (0.0 à 1.0) via ImageMagick.
    Utilise une approche plus robuste avec fallback.
    """
    # Essai avec ImageMagick 7 (magick)
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
    
    print(f"Erreur lecture {filepath.name}, utilisation valeur par défaut", file=sys.stderr)
    return 0.5


def load_cache() -> Dict[str, float]:
    """Charge le cache de luminosité depuis le fichier YAML."""
    if not CACHE_FILE.exists():
        return {}
    
    try:
        with open(CACHE_FILE, 'r') as f:
            cache = yaml.safe_load(f)
            return cache if isinstance(cache, dict) else {}
    except (yaml.YAMLError, IOError):
        return {}


def save_cache(cache: Dict[str, float]) -> None:
    """Sauvegarde le cache dans le fichier YAML."""
    try:
        with open(CACHE_FILE, 'w') as f:
            yaml.dump(cache, f, default_flow_style=False, allow_unicode=True)
    except IOError as e:
        print(f"Erreur sauvegarde cache : {e}", file=sys.stderr)


def get_weather_modifier(weather_factors: Dict[str, float]) -> Tuple[float, str]:
    """
    Récupère la météo et retourne un multiplicateur de luminosité + description.
    """
    try:
        cmd = ["curl", "-s", "-m", "5", "wttr.in/?format=j1"]
        result = subprocess.check_output(cmd, timeout=6).decode("utf-8")
        import json
        data = json.loads(result)
        condition = data['current_condition'][0]['weatherDesc'][0]['value']
        
        # Recherche partielle (ex: "Light Rain" match "Rain")
        for key, factor in weather_factors.items():
            if key.lower() in condition.lower():
                return factor, condition
        
        return 1.0, condition
    except Exception as e:
        print(f"Météo indisponible ({e}), ciel clair assumé")
        return 1.0, "Clear (fallback)"


def get_time_target() -> float:
    """
    Retourne une cible de luminosité basée sur l'heure (Cosinusoïdale).
    1.0 à 13h (midi solaire), 0.0 à 1h du matin.
    """
    now = datetime.datetime.now()
    hour = now.hour + now.minute / 60.0
    # Cosinus décalé : max à 13h, min à 1h
    base_brightness = (math.cos((hour - 13) * math.pi / 12) + 1) / 2
    return base_brightness


def init_swww() -> None:
    """Vérifie si le daemon swww tourne, sinon le lance."""
    try:
        subprocess.check_call(
            ["swww", "query"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=2
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        print("Démarrage swww-daemon...")
        subprocess.Popen(
            ["swww-daemon"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )
        time.sleep(1.5)


def find_wallpapers(wall_dir: Path) -> List[Path]:
    """Trouve tous les fichiers d'images dans le répertoire."""
    files = []
    for ext in IMAGE_EXTENSIONS:
        # Gère les extensions en minuscules et majuscules
        files.extend(wall_dir.glob(f"*{ext}"))
        files.extend(wall_dir.glob(f"*{ext.upper()}"))
    return sorted(set(files))


def select_wallpaper(
    files_with_brightness: List[Tuple[Path, float]],
    target: float,
    pool_size: int
) -> Tuple[Path, float]:
    """
    Sélectionne un wallpaper parmi les plus proches de la cible.
    """
    if not files_with_brightness:
        raise ValueError("Aucune image disponible")
    
    # Tri par distance à la cible
    sorted_files = sorted(
        files_with_brightness,
        key=lambda x: abs(x[1] - target)
    )
    
    # Sélection dans le pool
    candidates = sorted_files[:max(1, pool_size)]
    selected = random.choice(candidates)
    
    return selected


def apply_wallpaper(image_path: Path, swww_config: dict) -> None:
    """Applique le wallpaper via swww."""
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
        print(f"Erreur application wallpaper : {e}", file=sys.stderr)
        sys.exit(1)


def rebuild_cache(wall_dir: Path, force: bool = False) -> None:
    """Reconstruit le cache de luminosité."""
    print("Reconstruction du cache de luminosité...")
    files = find_wallpapers(wall_dir)
    
    if not files:
        print(f"Aucune image trouvée dans {wall_dir}")
        return
    
    cache = {} if force else load_cache()
    updated = 0
    
    for filepath in files:
        name = filepath.name
        if force or name not in cache:
            print(f"Analyse : {name}")
            cache[name] = get_image_brightness(filepath)
            updated += 1
    
    save_cache(cache)
    print(f"Cache mis à jour : {updated} images analysées, {len(cache)} au total")


def main():
    parser = argparse.ArgumentParser(
        description="Gestionnaire de wallpapers adaptatif basé sur la luminosité"
    )
    parser.add_argument(
        '--rebuild-cache',
        action='store_true',
        help="Reconstruit le cache de luminosité pour toutes les images"
    )
    parser.add_argument(
        '--force-change',
        action='store_true',
        help="Force le changement de wallpaper immédiatement"
    )
    parser.add_argument(
        '--show-target',
        action='store_true',
        help="Affiche la luminosité cible actuelle sans changer le wallpaper"
    )
    
    args = parser.parse_args()
    
    # 1. Chargement Config
    config = load_config()
    wall_dir = BASE_DIR
    pool_size = config.get('variability_pool', 10)
    
    if not wall_dir.exists():
        print(f"Erreur : Répertoire {wall_dir} introuvable", file=sys.stderr)
        sys.exit(1)
    
    # 2. Gestion des commandes spéciales
    if args.rebuild_cache:
        rebuild_cache(wall_dir, force=True)
        return
    
    # 3. Calcul de la cible
    time_target = get_time_target()
    weather_mod, weather_desc = get_weather_modifier(
        config.get('weather_factors', {})
    )
    final_target = max(0.0, min(1.0, time_target * weather_mod))
    
    print(f"Heure : {datetime.datetime.now().strftime('%H:%M')}")
    print(f"Luminosité temporelle : {time_target:.2f}")
    print(f"Météo : {weather_desc} (×{weather_mod})")
    print(f"Cible finale : {final_target:.2f}")
    
    if args.show_target:
        return
    
    # 4. Chargement images et cache
    files = find_wallpapers(wall_dir)
    if not files:
        print(f"Aucune image trouvée dans {wall_dir}")
        sys.exit(1)
    
    cache = load_cache()
    updated_cache = False
    valid_files = []
    
    for filepath in files:
        name = filepath.name
        if name not in cache:
            print(f"Nouvelle image détectée : {name}")
            cache[name] = get_image_brightness(filepath)
            updated_cache = True
        valid_files.append((filepath, cache[name]))
    
    if updated_cache:
        save_cache(cache)
    
    # 5. Initialisation swww
    init_swww()
    
    # 6. Sélection et application
    try:
        selected_image, brightness = select_wallpaper(
            valid_files,
            final_target,
            pool_size
        )
        
        print(f"Pool de sélection : {min(pool_size, len(valid_files))} images")
        print(f"Image sélectionnée : {selected_image.name}")
        print(f"Luminosité : {brightness:.2f} (Δ = {abs(brightness - final_target):.2f})")
        
        apply_wallpaper(selected_image, config.get('swww', {}))
        
    except ValueError as e:
        print(f"Erreur : {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
