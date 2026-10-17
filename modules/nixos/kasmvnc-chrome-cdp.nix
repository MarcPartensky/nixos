# Module KasmVNC Chrome CDP : lance Chromium avec le Chrome DevTools Protocol
# (remote debugging) dans la session Plasma de KasmVNC, pour Playwright MCP.
#
# POURQUOI un module separe et pas du code inline dans le profil : un module NixOS
# ne doit PAS lire `config.<ses propres options>` dans son `let` au niveau racine
# (ca part en « infinite recursion »). La forme correcte est options + `config =
# mkIf cfg.enable { ... }`, comme ici.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.kasmvnc.chrome-cdp;
  kasmUser = config.services.kasmvnc.user;
  browserPkg = if cfg.browser == "google-chrome" then pkgs.google-chrome else pkgs.chromium;
  browserBin = if cfg.browser == "google-chrome" then "google-chrome-stable" else "chromium";
  # NixOS ne connait PAS users.users.<u>.xdg.autostart (c'est du home-manager, et
  # le home de marc n'est pas gere par cette nixosConfiguration) : on ecrit le
  # .desktop via tmpfiles, pointant sur un lanceur.
  chromeCdpLauncher = pkgs.writeShellScript "chrome-cdp-launch" ''
    exec ${browserPkg}/bin/${browserBin} \
      --remote-debugging-port=${toString cfg.port} \
      --remote-debugging-address=${cfg.bindAddress} \
      --user-data-dir=${cfg.profileDir} \
      ${lib.concatStringsSep " " cfg.extraFlags} \
      about:blank
  '';
  chromeCdpDesktop = pkgs.writeText "chrome-cdp.desktop" ''
    [Desktop Entry]
    Type=Application
    Name=Chrome CDP
    Comment=Chrome with Chrome DevTools Protocol for Playwright MCP
    Exec=${chromeCdpLauncher}
    Terminal=false
    Categories=Network;WebBrowser;
    OnlyShowIn=KDE;
  '';
in {
  options.services.kasmvnc.chrome-cdp = {
    enable = lib.mkEnableOption "Chrome/Chromium avec CDP dans la session KasmVNC";
    browser = lib.mkOption {
      type = lib.types.enum [ "chromium" "google-chrome" ];
      default = "chromium";
      description = "Navigateur a installer et lancer";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 9222;
      description = "Port de debug CDP";
    };
    bindAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Adresse d'ecoute CDP (loopback par defaut : jamais au LAN)";
    };
    profileDir = lib.mkOption {
      type = lib.types.str;
      default = "/home/${kasmUser}/chrome-cdp-profile";
      description = "Repertoire de profil Chrome persistant";
    };
    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Flags Chrome supplementaires";
    };
    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Ouvrir le port CDP au firewall (deconseille : CDP = controle total)";
    };
    exposePublic = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Exposer CDP via Pangolin (SSO requis)";
    };
    publicDomain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Domaine public CDP";
    };
  };

  config = lib.mkIf cfg.enable {
    services.kasmvnc.extraPackages = [ browserPkg ];

    systemd.tmpfiles.rules = [
      "d ${cfg.profileDir} 0700 ${kasmUser} users - -"
      "d /home/${kasmUser}/.config/autostart 0755 ${kasmUser} users - -"
      "L+ /home/${kasmUser}/.config/autostart/chrome-cdp.desktop - - - - ${chromeCdpDesktop}"
    ];

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
