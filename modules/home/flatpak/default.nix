{ pkgs, ... }:
{
  services.flatpak = {
    enable = true;
    packages = [
      "com.github.d4nj1.tlpui"
    ];
  };
}

