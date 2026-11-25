# Client YouTube Music TUI "ytm-player" (github:peternaame-boop/ytm-player).
# "full" variant: MPRIS, synced lyrics, Discord, Last.fm, Spotify import.
{pkgs, inputs, ...}: {
  home.packages = [
    inputs.ytm-player.packages.${pkgs.stdenv.hostPlatform.system}.ytm-player-full
  ];
}
