{ ... }: {
  services.gammastep = {
    enable = true;
    provider = "manual";
    latitude = 48.0;
    longitude = 2.0;
    settings = {
      general = {
        # Definit la luminosite
        brightness-day = 1.0;
        brightness-night = 0.4;
      };
    };
  };
}
