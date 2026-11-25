{ pkgs, ... }:
{
  services.keyd = {
    enable = true;
    keyboards = {
      default = {  # Applies to all keyboards
        ids = [ "*" ];
        settings = {
          main = {
            # Keep your Caps Lock -> Escape mapping
            # capslock = "esc";
            # Map PgDn as left Shift
            # pgdn = "leftshift";
            pagedown = "layer(shift)";
          };
        };
      };
    };
  };
}
