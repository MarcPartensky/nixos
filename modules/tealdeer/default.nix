{ pkgs, ... }: {
  home-manager.users.marc = { pkgs, inputs, ... }: {
    programs.tealdeer = {
      enable = true;
      enableAutoUpdates = true;
      settings = {
        display = {
          compact = false;
          use_pager = true;
        };
        updates = {
          auto_update = true;
        };
      };
    };
  };
}
