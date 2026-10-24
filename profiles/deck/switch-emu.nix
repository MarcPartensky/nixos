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

  # Lance MK8DX directement, sans passer par l'UI d'Eden.
  # Sélection du fichier, par ordre de préférence :
  #   1. un fichier portant le Title ID de BASE 0100152000022000 ;
  #   2. sinon un fichier qui n'est ni un update ni un DLC ;
  #   3. sinon le premier .nsp/.xci trouvé.
  # Indispensable dès que l'update 4.0.0 (0100152000022800) est posé dans le
  # dossier : Eden applique tout seul l'update présent à côté du jeu de base,
  # mais lancer le NSP d'update comme s'il était le jeu échoue.
  mk8dx = pkgs.writeShellScriptBin "mk8dx" ''
    # Steam injecte ses libs runtime via LD_LIBRARY_PATH, ce qui peut casser un binaire Nix
    unset LD_LIBRARY_PATH
    list="$(${pkgs.findutils}/bin/find "$HOME/Games/switch" -maxdepth 1 -type f \( -name '*.nsp' -o -name '*.xci' \) 2>/dev/null | ${pkgs.coreutils}/bin/sort)"
    game="$(printf '%s\n' "$list" | ${pkgs.gnugrep}/bin/grep -i '0100152000022000' | ${pkgs.coreutils}/bin/head -n 1)"
    if [ -z "$game" ]; then
      game="$(printf '%s\n' "$list" | ${pkgs.gnugrep}/bin/grep -viE 'update|dlc' | ${pkgs.coreutils}/bin/head -n 1)"
    fi
    if [ -z "$game" ]; then
      game="$(printf '%s\n' "$list" | ${pkgs.coreutils}/bin/head -n 1)"
    fi
    if [ -z "$game" ]; then
      echo "mk8dx : aucun fichier .nsp/.xci dans ~/Games/switch" >&2
      exit 1
    fi
    exec ${lib.getExe pkgs.eden} -f -g "$game"
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

  # Tuile « Mario Kart 8 Deluxe » en Gaming Mode : même script que la commande
  # mk8dx (choix automatique du .nsp/.xci présent dans ${games}).
  programs.steam.config.nonSteamApps."Mario Kart 8 Deluxe".target = mk8dx;

  # Clés Switch (prod.keys) : chiffrées dans secrets/switch-keys.yml, écrites
  # ici à l'activation, owned marc. Mise à jour = réencrypter + rebuild.
  sops.secrets."prod_keys" = {
    sopsFile = ../../secrets/switch-keys.yml;
    path = "${home}/.local/share/eden/keys/prod.keys";
    owner = user;
    group = group;
    mode = "0600";
  };

  # Mêmes clés pour Ryubing (fork Ryujinx), qui lit ~/.config/Ryujinx/system/
  sops.secrets."prod_keys_ryujinx" = {
    sopsFile = ../../secrets/switch-keys.yml;
    key = "prod_keys";
    path = "${home}/.config/Ryujinx/system/prod.keys";
    owner = user;
    group = group;
    mode = "0600";
  };

  # Dossiers eden (clés ; le nand reste à installer via la GUI ou une copie)
  # + dossiers Ryubing + dossier des dumps : jeu de base + update + DLC
  systemd.tmpfiles.rules = [
    "d ${home}/.local/share/eden 0755 ${user} ${group} -"
    "d ${home}/.local/share/eden/keys 0700 ${user} ${group} -"
    "d ${home}/.config/Ryujinx 0755 ${user} ${group} -"
    "d ${home}/.config/Ryujinx/system 0755 ${user} ${group} -"
    "d ${home}/Games 0755 ${user} ${group} -"
    "d ${games} 0755 ${user} ${group} -"
  ];

  # Accès de l'agent hermes (maintenance sans intervention de marc) aux
  # données des émulateurs + dumps : traverse du home + rwX récursif sur ces
  # dossiers uniquement, le reste du home de marc reste inaccessible.
  # Idempotent, réappliqué à chaque activation.
  system.activationScripts.hermes-switch-emu-access.text = ''
    ${pkgs.acl}/bin/setfacl -m u:hermes:x ${home} || true
    for d in ${home}/.local/share/eden ${home}/.config/eden ${home}/.config/Ryujinx ${home}/Games; do
      if [ -d "$d" ]; then ${pkgs.acl}/bin/setfacl -R -m u:hermes:rwX "$d" || true; fi
    done

    # Firmware Switch (NCAs copiés par l'agent) : doit appartenir à marc.
    # Eden l'ouvre en lecture+ÉCRITURE (r+b, cf. mode=3 dans eden_log.txt) et
    # échoue sinon : « Installed firmware: No firmware available » puis crash
    # au chargement du menu (cas MK8DX). Un simple chmod 666 ne suffit pas :
    # marc est dans le groupe hermes, donc l'entrée ACL group::r-- gagne sur
    # « other ». On remet donc l'ownership attendu par Eden (marc:users).
    for d in ${home}/.local/share/eden/nand/system/Contents/registered ${home}/.config/Ryujinx/bis/system/Contents/registered; do
      if [ -d "$d" ]; then ${pkgs.coreutils}/bin/chown -R ${user}:${group} "$d" || true; fi
    done
  '';

  # Manettes BT en plus (Pro Controller, Joy-Con) pour le multi local
  hardware.bluetooth.enable = true;

  # Uniquement pour HÉBERGER un salon online Eden (port par défaut hérité de yuzu)
  # networking.firewall.allowedUDPPorts = [ 24872 ];
}
