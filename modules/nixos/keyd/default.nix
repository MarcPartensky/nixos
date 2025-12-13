{ pkgs, ... }:
{
  services.keyd = {
    enable = true;
    keyboards = {
      default = {  # Applique à tous les claviers
        ids = [ "*" ];
        settings = {
          main = {
            # Conservez votre mapping Caps Lock -> Échap
            # capslock = "esc";
            # Mappez PgDn comme Shift gauche
            # pgdn = "leftshift";
            pagedown = "layer(shift)";
          };
        };
      };
    };
  };
}
