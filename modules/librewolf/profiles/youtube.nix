{ pkgs, lib, ... }:
{
  home-manager.users.marc = { pkgs, inputs, ... }: {

    programs.firefox = {
      profiles.youtube = {
        id = 1;
        # extensions = []
        name = "Youtube";
        settings = {          # specify profile-specific preferences here; check about:config for options
          "browser.newtabpage.activity-stream.feeds.section.highlights" = false;
          "browser.startup.homepage" = "https://youtube.com";
          "browser.newtabpage.pinned" = [{
            title = "Youtube";
            url = "https://youtube.com";
          }];
        };
      };
    };
  };
}
