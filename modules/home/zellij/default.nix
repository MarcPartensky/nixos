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
      # mkForce : depuis le bump de l'input catppuccin, son module home-manager
      # definit aussi programs.zellij.settings.theme (valeur "catppuccin-mocha",
      # tiree de catppuccin.flavor) et l'eval echoue en "conflicting definition
      # values" sans priorite explicite. On garde ici le choix de marc.
      theme = lib.mkForce "catppuccin-latte"; # ou "catppuccin-mocha"
      default_layout = "compact";      # une seule barre, plus de place
      pane_frames = false;
      scroll_buffer_size = 50000;
      copy_on_select = true;
      show_startup_tips = false;
      show_release_notes = false;

      # Ctrl+o belongs to the pane application: the Hermes TUI opens its model
      # picker with it (Ctrl+o), nvim opens Neo-tree. In "locked" mode zellij
      # takes only Ctrl+g, so both keep working. The session manager is bound
      # here so it can be opened without unlocking zellij first: Ctrl+Shift+o is
      # distinct from Ctrl+o under the kitty keyboard protocol, which zellij
      # requests and Alacritty implements.
      keybinds.locked._children = [
        {
          bind = {
            _args = [ "Ctrl Shift o" ];
            _children = [
              {
                LaunchOrFocusPlugin = {
                  _args = [ "session-manager" ];
                  _children = [
                    { floating = true; }
                    { move_to_focused_tab = true; }
                  ];
                };
              }
            ];
          };
        }
      ];
    };
  };
}
