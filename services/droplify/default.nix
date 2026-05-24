{ pkgs, ...}:{
  imports = [ ./modules/droplify.nix ];
  
  services.droplify = {
    enable = true;
    domain = "drop.marcpartensky.com";
    port   = 8089;
  };
}
