{ ... }:
{
  programs.clawdbot = {
    enable = true;
    systemd.enable = false;

    firstParty = {
      summarize.enable = false;   # Summarize web pages, PDFs, videos
      peekaboo.enable = false;    # Take screenshots
      oracle.enable = false;     # Web search
      poltergeist.enable = false; # Control your macOS UI
      sag.enable = false;        # Text-to-speech
      camsnap.enable = false;    # Camera snapshots
      gogcli.enable = false;     # Google Calendar
      bird.enable = false;       # Twitter/X
      sonoscli.enable = false;   # Sonos control
      imsg.enable = false;       # iMessage
    };

    instances.default = {
      enable = true;
      agent = {
        model = "anthropic/claude-opus-4-5";
      };
    };
  };
}
