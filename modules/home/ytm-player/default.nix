# Client YouTube Music TUI "ytm-player" (github:peternaame-boop/ytm-player).
# Variante "full" : MPRIS, lyrics synchronisés, Discord, Last.fm, import Spotify.
{pkgs, inputs, ...}: {
  home.packages = [
    inputs.ytm-player.packages.${pkgs.stdenv.hostPlatform.system}.ytm-player-full
  ];
}
