{ config, pkgs, ... }:

let
  gitInfo = pkgs.runCommand "nixos-git-info"
    { nativeBuildInputs = [ pkgs.git ]; }
    ''
      cp -r ${config.system.build.source or ./../../.} repo
      cd repo || exit 1

      # Résout HEAD (si clone shallow)
      git fetch --unshallow 2>/dev/null || true

      SHA="$(git rev-parse --short HEAD)"
      MSG="$(git log -1 --pretty=%s)"

      echo -n "$SHA $MSG" > $out
    '';
in
{
  system.configurationRevision = builtins.readFile gitInfo;
  system.nixos.label = "nixos-${config.system.configurationRevision}";
}

