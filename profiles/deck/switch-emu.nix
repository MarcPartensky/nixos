# profiles/deck/switch-emu.nix
{
  config,
  lib,
  pkgs,
  ...
}: let
  user = config.jovian.steam.user; # ton user du mode Jeu
  home = config.users.users.${user}.home;
  group = config.users.users.${user}.group;
  games = "${home}/Games/switch";

  # Lance MK8DX directement, sans passer par l'UI d'Eden
  mk8dx = pkgs.writeShellScriptBin "mk8dx" ''
    # Steam injecte ses libs runtime via LD_LIBRARY_PATH, ce qui peut casser un binaire Nix
    unset LD_LIBRARY_PATH
    exec ${lib.getExe pkgs.eden} -f -g "${games}/MK8DX.xci"
  '';

  # Entrée de menu : apparaît dans « Ajouter un jeu non-Steam »
  mk8dxDesktop = pkgs.makeDesktopItem {
    name = "mk8dx";
    desktopName = "Mario Kart 8 Deluxe";
    exec = lib.getExe mk8dx;
    icon = "applications-games";
    categories = ["Game"];
  };
in {
  environment.systemPackages = [
    pkgs.eden # fork yuzu, le plus fluide sur Deck
    pkgs.ryubing # fork Ryujinx, plan B en cas de bug graphique
    mk8dx
    mk8dxDesktop
  ];

  # Dossier des dumps : jeu de base + update + DLC
  systemd.tmpfiles.rules = [
    "d ${home}/Games 0755 ${user} ${group} -"
    "d ${games} 0755 ${user} ${group} -"
  ];

  # Manettes BT en plus (Pro Controller, Joy-Con) pour le multi local
  hardware.bluetooth.enable = true;

  # Uniquement pour HÉBERGER un salon online Eden (port par défaut hérité de yuzu)
  # networking.firewall.allowedUDPPorts = [ 24872 ];
}
