# profiles/deck/switch-emu.nix
{
  config,
  lib,
  pkgs,
  ...
}: let
  user = config.jovian.steam.user; # your Game mode user
  home = config.users.users.${user}.home;
  group = config.users.users.${user}.group;
  games = "${home}/Games/switch";

  # Launches MK8DX directly, without going through Eden's UI.
  # File selection, by order of preference:
  #   1. a file carrying the BASE Title ID 0100152000022000;
  #   2. otherwise a file that is neither an update nor a DLC;
  #   3. otherwise the first .nsp/.xci found.
  # Essential as soon as update 4.0.0 (0100152000022800) is placed in the
  # folder: Eden automatically applies the update present next to the base game,
  # but launching the update NSP as if it were the game fails.
  mk8dx = pkgs.writeShellScriptBin "mk8dx" ''
    # Steam injects its runtime libs via LD_LIBRARY_PATH, which can break a Nix binary
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
      echo "mk8dx: no .nsp/.xci file in ~/Games/switch" >&2
      exit 1
    fi
    exec ${lib.getExe pkgs.eden} -f -g "$game"
  '';

  # Menu entry: appears in "Add a non-Steam game"
  mk8dxDesktop = pkgs.makeDesktopItem {
    name = "mk8dx";
    desktopName = "Mario Kart 8 Deluxe";
    exec = lib.getExe mk8dx;
    icon = "applications-games";
    categories = ["Game"];
  };
in {
  environment.systemPackages = [
    pkgs.eden # yuzu fork, the smoothest on Deck
    pkgs.ryubing # Ryujinx fork, plan B in case of a graphics bug
    mk8dx
    mk8dxDesktop
  ];

  # "Mario Kart 8 Deluxe" tile in Gaming Mode: same script as the mk8dx
  # command (automatic choice of the .nsp/.xci present in ${games}).
  programs.steam.config.nonSteamApps."Mario Kart 8 Deluxe".target = mk8dx;

  # Switch keys (prod.keys): encrypted in secrets/switch-keys.yml, written
  # here at activation, owned marc. Update = re-encrypt + rebuild.
  sops.secrets."prod_keys" = {
    sopsFile = ../../secrets/switch-keys.yml;
    path = "${home}/.local/share/eden/keys/prod.keys";
    owner = user;
    group = group;
    mode = "0600";
  };

  # Same keys for Ryubing (Ryujinx fork), which reads ~/.config/Ryujinx/system/
  sops.secrets."prod_keys_ryujinx" = {
    sopsFile = ../../secrets/switch-keys.yml;
    key = "prod_keys";
    path = "${home}/.config/Ryujinx/system/prod.keys";
    owner = user;
    group = group;
    mode = "0600";
  };

  # eden folders (keys; the nand remains to be installed via the GUI or a copy)
  # + Ryubing folders + dumps folder: base game + update + DLC
  systemd.tmpfiles.rules = [
    "d ${home}/.local/share/eden 0755 ${user} ${group} -"
    "d ${home}/.local/share/eden/keys 0700 ${user} ${group} -"
    "d ${home}/.config/Ryujinx 0755 ${user} ${group} -"
    "d ${home}/.config/Ryujinx/system 0755 ${user} ${group} -"
    "d ${home}/Games 0755 ${user} ${group} -"
    "d ${games} 0755 ${user} ${group} -"
  ];

  # Access of the hermes agent (maintenance without marc's intervention) to
  # the emulator + dump data: traversal of the home + recursive rwX on these
  # folders only, the rest of marc's home stays inaccessible.
  # Idempotent, reapplied on every activation.
  system.activationScripts.hermes-switch-emu-access.text = ''
    ${pkgs.acl}/bin/setfacl -m u:hermes:x ${home} || true
    for d in ${home}/.local/share/eden ${home}/.config/eden ${home}/.config/Ryujinx ${home}/Games; do
      if [ -d "$d" ]; then ${pkgs.acl}/bin/setfacl -R -m u:hermes:rwX "$d" || true; fi
    done

    # Switch firmware (NCAs copied by the agent): must belong to marc.
    # Eden opens it read+WRITE (r+b, cf. mode=3 in eden_log.txt) and
    # fails otherwise: "Installed firmware: No firmware available" then crash
    # on loading the menu (MK8DX case). A simple chmod 666 is not enough:
    # marc is in the hermes group, so the ACL entry group::r-- wins over
    # "other". So the ownership expected by Eden (marc:users) is restored.
    for d in ${home}/.local/share/eden/nand/system/Contents/registered ${home}/.config/Ryujinx/bis/system/Contents/registered; do
      if [ -d "$d" ]; then ${pkgs.coreutils}/bin/chown -R ${user}:${group} "$d" || true; fi
    done
  '';

  # Extra BT controllers (Pro Controller, Joy-Con) for local multiplayer
  hardware.bluetooth.enable = true;

  # Only to HOST an Eden online room (default port inherited from yuzu)
  # networking.firewall.allowedUDPPorts = [ 24872 ];
}
