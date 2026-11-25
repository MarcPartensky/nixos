{ lib, config, ... }:
let
  cfg = config.my.zellij;
in
{
  options.my.zellij.autostart = lib.mkEnableOption "auto-launch of zellij in interactive shells";

  config.programs.zellij = {
    enable = true;
    enableZshIntegration = cfg.autostart;
    enableBashIntegration = cfg.autostart;
    attachExistingSession = true;  # attaches instead of creating a new session
    exitShellOnExit = true;        # quitting zellij closes the connection

    settings = {
      on_force_close = "detach";       # cutoff = detach, kills nothing
      session_serialization = true;    # restores sessions after reboot
      default_mode = "locked";         # no shortcut conflicts (Ctrl+g to unlock)
      # mkForce: since the catppuccin input bump, its home-manager module
      # also defines programs.zellij.settings.theme (value "catppuccin-mocha",
      # taken from catppuccin.flavor) and the eval fails with "conflicting definition
      # values" without an explicit priority. We keep marc's choice here.
      theme = lib.mkForce "catppuccin-latte"; # or "catppuccin-mocha"
      default_layout = "compact";      # a single bar, more space
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
