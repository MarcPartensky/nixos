{ lib, config, ... }:
let
  cfg = config.my.zellij;
in
{
  options.my.zellij.autostart = lib.mkEnableOption "lancement auto de zellij dans les shells interactifs";

  config.programs.zellij = {
    enable = true;
    enableZshIntegration = cfg.autostart;
    enableBashIntegration = cfg.autostart;
    attachExistingSession = true;  # se rattache au lieu de créer une nouvelle session
    exitShellOnExit = true;        # quitter zellij ferme la connexion

    settings = {
      on_force_close = "detach";       # coupure = détache, ne tue rien
      session_serialization = true;    # restaure les sessions après reboot
      default_mode = "locked";         # pas de conflit de raccourcis (Ctrl+g pour déverrouiller)
      theme = "catppuccin-latte";      # ou "catppuccin-mocha"
      default_layout = "compact";      # une seule barre, plus de place
      pane_frames = false;
      scroll_buffer_size = 50000;
      copy_on_select = true;
      show_startup_tips = false;
      show_release_notes = false;
    };
  };
}
