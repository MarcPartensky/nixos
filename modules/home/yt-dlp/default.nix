{ pkgs, ...}:
{
  programs.yt-dlp = {
    enable = true;
    settings = {
      continue = true;
      ignore-errors = true;
      no-overwrites = true;
      output = "%(title)s.%(ext)s";
      format = "bestvideo[ext=mp4]+bestaudio[ext=m4a]/bestvideo+bestaudio";
      progress = true;
      audio-quality = 0;
      embed-thumbnail = true;
      embed-metadata = true;
      embed-subs = true;
      embed-chapters = true;
      embed-info-json = true;
      rm-cache-dir = true;
      no-keep-fragments = true;
      sponsorblock-mark = "all";
      sponsorblock-remove = "all";
      retry-sleep = 10;
      retries = 1000;
      file-access-retries = 1000;
      extractor-retries = 1000;
    };
  };
}
