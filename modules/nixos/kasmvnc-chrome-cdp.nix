# KasmVNC Chrome CDP module: launches Chromium with the Chrome DevTools Protocol
# (remote debugging) in the KasmVNC Plasma session, for Playwright MCP.
#
# WHY a separate module and not inline code in the profile: a NixOS module
# must NOT read `config.<its own options>` in its root-level `let`
# (that turns into "infinite recursion"). The correct form is options + `config =
# mkIf cfg.enable { ... }`, like here.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.kasmvnc.chrome-cdp;
  kasmUser = config.services.kasmvnc.user;
  browserPkg = if cfg.browser == "google-chrome" then pkgs.google-chrome else pkgs.chromium;
  browserBin = if cfg.browser == "google-chrome" then "google-chrome-stable" else "chromium";
  # NixOS does NOT know users.users.<u>.xdg.autostart (that is home-manager, and
  # marc's home is not managed by this nixosConfiguration): we write the
  # .desktop via tmpfiles, pointing to a launcher.
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
    enable = lib.mkEnableOption "Chrome/Chromium with CDP in the KasmVNC session";
    browser = lib.mkOption {
      type = lib.types.enum [ "chromium" "google-chrome" ];
      default = "chromium";
      description = "Browser to install and launch";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 9222;
      description = "CDP debug port";
    };
    bindAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "CDP listen address (loopback by default: never on the LAN)";
    };
    profileDir = lib.mkOption {
      type = lib.types.str;
      default = "/home/${kasmUser}/chrome-cdp-profile";
      description = "Persistent Chrome profile directory";
    };
    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional Chrome flags";
    };
    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the CDP port to the firewall (not advised: CDP = full control)";
    };
    exposePublic = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Expose CDP via Pangolin (SSO required)";
    };
    publicDomain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "CDP public domain";
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
