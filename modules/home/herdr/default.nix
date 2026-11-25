{
  config,
  lib,
  ...
}: {
  # --- herdr: marc's config, placed by home-manager ---
  # herdr (agent multiplexer, github:ogulcancelik/herdr) has no NixOS
  # option and the `programs.herdr` module does not yet exist in the
  # pinned home-manager (verified: no modules/programs/herdr.nix in
  # the input), so the file is declared here and placed by xdg.configFile.
  #
  # Content: see modules/home/herdr/config.toml (sidebar rows that
  # display the hermes model of each pane, via the OSC title written by the
  # TUI; on the hermes side, this assumes display.interface = "tui", cf
  # services/hermes/default.nix).
  #
  # Hot application after a switch: `herdr server reload-config`
  # (or global menu -> reload config). An already-launched client keeps its old
  # config until the reload.
  # `force = true`: the 1st activation of the system HM otherwise stumbles on the old
  # symlink /home/marc/.config/herdr/config.toml left by the
  # systemd.tmpfiles version (it does not look like a home-manager-files file, so
  # check-link-targets declares it "would be clobbered" and the activation fails
  # with status=1). force skips this check and replaces the link.
  xdg.configFile."herdr/config.toml" = {
    force = true;
    text = builtins.readFile ./config.toml;
  };
}
