{ pkgs, home-manager, inputs, ... }:

{
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = { inherit inputs; };
    backupFileExtension = "backup";
    sharedModules = [
      inputs.nixvim.homeModules.nixvim
    ];
  };

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


  home-manager.users.marc = import ./home.nix;
}

