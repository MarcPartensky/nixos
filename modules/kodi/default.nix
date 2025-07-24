{ pkgs, ... }: {

  # users.extraUsers.kodi.isNormalUser = true;
  # services.cage.user = "kodi";
  # services.cage.program = "${pkgs.kodi-wayland}/bin/kodi-standalone";
  # services.cage.enable = true;

  environment.systemPackages = [
	(pkgs.kodi.withPackages (kodiPkgs: with kodiPkgs; [
		jellyfin
	]))
  ];


  # Define a user account
  home-manager.users.marc = { pkgs, inputs, ... }: {

    home.packages = with pkgs; [
   #    (kodi.withPackages (kodiPkgs: with kodiPkgs; [
	  # 	jellyfin
	  # ]))
    ];
  };
}
