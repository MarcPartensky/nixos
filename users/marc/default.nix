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

  home-manager.users.marc = import ./home.nix;
}

