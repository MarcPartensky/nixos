# services/ygg-mesh/darwin.nix
#
# Côté macOS (nix-darwin) du réseau ygg-mesh : paquet + client Tor + daemon.
# Importé par profiles/macos/configuration.nix. Le module NixOS de ce réseau
# vit dans services/ygg-mesh/default.nix ; le fichier de config Yggdrasil
# (/etc/yggdrasil.conf) est décrit dans son en-tête et n'est PAS posé par le
# nix store (il contient le mot de passe partagé).
#
# Ce que ce module installe :
#   - yggdrasil + tor (paquets nixpkgs, 0.5.13 / 0.4.9 comme les nœuds Linux) ;
#   - tor en client SOCKS (127.0.0.1:9050) : sortie vers les onions du mesh et
#     des nœuds quand le Mac est hors du LAN ;
#   - le daemon yggdrasil qui lit /etc/yggdrasil.conf (à créer une fois,
#     root:wheel 0600). Sur le LAN, le lien direct multicast prend le relais.
#
# Le torrc ne contient aucun secret (juste des ports) : il peut vivre dans le
# store, contrairement à /etc/yggdrasil.conf.
#
# Config minimale de /etc/yggdrasil.conf (voir l'en-tête du module NixOS pour
# les valeurs à jour) : Listen = [], Peers = les URIs socks://…@127.0.0.1:9050
# vers les onions des nœuds, MulticastInterfaces { Beacon=false; Listen=true;
# Port=12346; Password=<mot de passe> }, AllowedPublicKeys = les clés des nœuds.

{ pkgs, lib, ... }:

let
  torrc = pkgs.writeText "ygg-mesh-torrc" ''
    SocksPort 127.0.0.1:9050 IsolateDestAddr IsolateSOCKSAuth
    AvoidDiskWrites 1
    SafeLogging 1
  '';
in
{
  environment.systemPackages = [ pkgs.yggdrasil pkgs.tor ];

  # Daemons système (root) : yggdrasil crée une interface utun, tor ouvre le
  # SOCKS en loopback. nix-darwin attend le montage du store au boot avant de
  # lancer la commande (wait4path).
  launchd.daemons.ygg-mesh-tor = {
    command = "${pkgs.tor}/bin/tor -f ${torrc}";
    serviceConfig = {
      KeepAlive = true;
      RunAtLoad = true;
      StandardOutPath = "/var/log/ygg-mesh-tor.log";
      StandardErrorPath = "/var/log/ygg-mesh-tor.log";
    };
  };

  launchd.daemons.yggdrasil = {
    command = "${pkgs.yggdrasil}/bin/yggdrasil -useconffile /etc/yggdrasil.conf";
    serviceConfig = {
      KeepAlive = true;
      RunAtLoad = true;
      StandardOutPath = "/var/log/yggdrasil.log";
      StandardErrorPath = "/var/log/yggdrasil.log";
    };
  };
}
