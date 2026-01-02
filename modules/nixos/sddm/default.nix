{ pkgs, ... }:

{
  # 1. Activer Niri (gère l'installation et le fichier de session)
  programs.niri.enable = true;

  # 2. Configurer le Display Manager (SDDM)
  services.displayManager = {
    sddm.enable = true;
    sddm.wayland.enable = true; # Recommandé pour Niri (Wayland natif)
    
    # 3. Configurer l'AutoLogin
    autoLogin = {
      enable = true;
      user = "marc"; # <--- Remplace par ton pseudo
    };
    
    # Définir la session par défaut sur niri
    defaultSession = "niri";
  };
}
