{ ... }:

{
  programs.ipython = {
    enable = true;

    # Profil par défaut (profile_default)
    profiles.default = {
      startupBanner = false;   # ← enlève le message d’accueil
    };
  };
  # Création du fichier de configuration IPython
  xdg.configFile."ipython/profile_default/ipython_config.py".text = ''
    c = get_config()

    # Active le mode d'édition Vi
    c.TerminalInteractiveShell.editing_mode = 'vi'

    # Optionnel : définit le délai de bascule (escape time) 
    # pour une transition plus rapide entre les modes
    c.TerminalInteractiveShell.emacs_bindings_in_vi_insert_mode = False
  '';

  # # Facultatif : `py` lance IPython en mode silencieux
  # programs.zsh.aliases = {
  #   py = "ipython -q";
  # };
}

