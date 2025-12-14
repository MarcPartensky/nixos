{ ... }: {
  services.gammastep = {
    enable = true;
    provider = "manual";
    latitude = 48.0;
    longitude = 2.0;
  };
}
