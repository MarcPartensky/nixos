{ config, pkgs, ... }:

{
  programs.ipython = {
    enable = true;

    # Profil par défaut (profile_default)
    profiles.default = {
      startupBanner = false;   # ← enlève le message d’accueil
    };
  };

  # Facultatif : `py` lance IPython en mode silencieux
  programs.bash.aliases = {
    py = "ipython -q";
  };
}

