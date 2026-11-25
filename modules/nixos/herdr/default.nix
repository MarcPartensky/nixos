{
  config,
  pkgs,
  lib,
  ...
}: {
  # --- herdr: marc's config placed by the system ---
  # herdr (agent multiplexer) has no NixOS option; its config lives in
  # ~/.config/herdr/config.toml and is used to display the hermes MODEL of each
  # pane in the sidebar (see modules/nixos/herdr/config.toml).
  #
  # Marc uses home-manager STANDALONE (users/marc/home.nix, `HM=marc just home`,
  # which hermes does not activate): so we place the file on the system side, as a
  # symlink to the store, exactly what xdg.configFile would do. A `just nixos`
  # is enough, without waiting for a home-manager generation.
  # (The home-manager module `programs.herdr` does not exist in the home-manager
  # pinned: xdg.configFile would be the only alternative, same mechanism.)
  #
  # Live effect: `herdr server reload-config` (or restarting the client). The file
  # is read-only (store): a manual edit of ~/.config/herdr/config.toml
  # does not stick, this file here is authoritative.
  systemd.tmpfiles.rules = [
    "d /home/marc/.config/herdr 0755 marc users -"
    "L+ /home/marc/.config/herdr/config.toml - - - - ${./config.toml}"
  ];
}
