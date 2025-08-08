{ pkgs, ... }:
{
  home-manager.users.marc = { pkgs, inputs, ... }: {

    programs.alacritty = {
      enable = true;
    
      settings = {
        window = {
          title = "Terminal";
          opacity = 0.9;
    
          padding = { y = 5; };
          dimensions = {
            lines = 75;
            columns = 100;
          };
        };
        keyboard.bindings = [
          # Copier avec Ctrl+C
          # { key = "C"; mods = "Control"; action = "Copy"; }
          # { key = "C"; mods = "Control"; action = "Copy"; }
          # Envoyer SIGINT (interruption) avec Ctrl+Maj+C
          # { key = "C"; mods = "Control|Shift"; action = "ReceiveChar"; chars = "\\x03"; }
          # Coller avec Ctrl+V
          # { key = "V"; mods = "Control"; action = "Paste"; }
          { key = "PageUp"; action = "Copy"; }
          { key = "PageUp"; mode = "Vi|~Search"; action = "Copy"; }
          { key = "PageDown"; action = "Paste"; }
          # { key = "PageDown"; mode = "Vi|~Search"; action = "Paste"; }
        ];
    
        font = {
          normal = {
            family = "MesloLGS NF";
            style = "Regular";
          };

          size = 15;
        };
    
    
        terminal.shell = { program = "${pkgs.zsh}/bin/zsh"; };
    
        # colors = {
        #   primary = {
        #     background = "0x000000";
        #     foreground = "0xEBEBEB";
        #   };
        #   cursor = {
        #     text = "0xFF261E";
        #     cursor = "0xFF261E";
        #   };
        #   normal = {
        #     black = "0x0D0D0D";
        #     red = "0xFF301B";
        #     green = "0xA0E521";
        #     yellow = "0xFFC620";
        #     blue = "0x178AD1";
        #     magenta = "0x9f7df5";
        #     cyan = "0x21DEEF";
        #     white = "0xEBEBEB";
        #   };
        #   bright = {
        #     black = "0x6D7070";
        #     red = "0xFF4352";
        #     green = "0xB8E466";
        #     yellow = "0xFFD750";
        #     blue = "0x1BA6FA";
        #     magenta = "0xB978EA";
        #     cyan = "0x73FBF1";
        #     white = "0xFEFEF8";
        #   };
        # };
      };
    };
  };
}
