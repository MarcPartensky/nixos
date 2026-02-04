{
  inputs,
  pkgs,
  ...
}: let
  # For Flakeless:
  # spicePkgs = spicetify-nix.packages;
  # With flakes:
  spicePkgs = inputs.spicetify.legacyPackages.${pkgs.stdenv.system};
in {
  programs.spicetify = {
    enable = true;
    enabledExtensions = with spicePkgs.extensions; [
      adblockify
      hidePodcasts
      shuffle # shuffle+ (special characters are sanitized out of extension names)
      trashbin
      bookmark
      keyboardShortcut
      history
      wikify
      # showQueueDuration
      queueTime
      betterGenres
    ];
    enabledCustomApps = with spicePkgs.apps; [
      localFiles
      historyInSidebar
      marketplace
    ];
    # theme = spicePkgs.themes.catppuccin;
    # theme = spicePkgs.themes.lucid;
    # theme = spicePkgs.themes.hazy;
    # theme = spicePkgs.themes.comfy;
    # theme = spicePkgs.themes.bloom;
    theme = spicePkgs.themes.defaultDynamic;
    # theme = spicePkgs.themes.sleek;
    # colorScheme = "mocha";
  };
}
