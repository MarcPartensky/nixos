{ config, pkgs, lib, ... }:
# Pont vocal Hermes : page web (micro navigateur) -> faster-whisper -> agent Hermes
# -> Pocket TTS francais. Le venv Python 3.12 vit hors store (pocket-tts n'est pas
# package dans nixpkgs) : /var/lib/hermes/hermes-voice, cree avec uv.
let
  venv = "/var/lib/hermes/hermes-voice";
  app = "/var/lib/hermes/hermes-voice/app";
  envFile = "/var/lib/hermes/.config/hermes-voice.env";
in {
  systemd.user.services.hermes-voice = {
    description = "Pont vocal Hermes (STT whisper + agent + TTS Pocket TTS)";
    wantedBy = [ "default.target" ];
    environment = {
      HOST = "0.0.0.0";
      PORT = "8999";
      WHISPER_SIZE = "small";
      TTS_LANG = "french";
      TTS_VOICE = "estelle";
      # N'accepter que la boucle locale (newt) et le tailnet : le domaine public
      # passe par newt, donc arrive en 127.0.0.1 ; le telephone en 100.64/10.
      ALLOW_NETS = "127.0.0.1/32,::1/128,100.64.0.0/10,fd7a:115c:a1e0::/48";
    };
    serviceConfig = {
      WorkingDirectory = app;
      ExecStart = "${venv}/bin/python ${app}/hermes_voice.py";
      EnvironmentFile = envFile;
      Restart = "always";
      RestartSec = "5s";
    };
  };

  # Domaine public derriere SSO Zitadel : l'endpoint donne acces a l'agent
  # (outils, fichiers), donc jamais sans authentification.
  services.newt.blueprint.proxy-resources.hermes-voice = {
    name = "hermes-voice";
    protocol = "http";
    full-domain = "voice.marcpartensky.com";
    auth.sso-enabled = true;
    targets = [{
      hostname = "127.0.0.1";
      port = 8999;
      method = "http";
      healthcheck = {
        enabled = true;
        hostname = "127.0.0.1";
        port = 8999;
        path = "/healthz";
        scheme = "http";
        mode = "http";
        method = "GET";
        interval = 30;
        unhealthy-interval = 30;
        timeout = 5;
        healthy-threshold = 1;
        unhealthy-threshold = 3;
      };
    }];
  };
}
