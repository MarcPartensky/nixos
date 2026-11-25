{ config, pkgs, lib, ... }:
# Hermes voice bridge: web page (browser mic) -> faster-whisper -> Hermes agent
# -> Pocket TTS French. The Python 3.12 venv lives outside the store (pocket-tts is not
# packaged in nixpkgs): /var/lib/hermes/hermes-voice, created with uv.
let
  venv = "/var/lib/hermes/hermes-voice";
  app = "/var/lib/hermes/hermes-voice/app";
  envFile = "/var/lib/hermes/.config/hermes-voice.env";
in {
  systemd.user.services.hermes-voice = {
    description = "Hermes voice bridge (STT whisper + agent + TTS Pocket TTS)";
    wantedBy = [ "default.target" ];
    environment = {
      HOST = "0.0.0.0";
      PORT = "8999";
      WHISPER_SIZE = "small";
      TTS_LANG = "french";
      TTS_VOICE = "estelle";
      # Accept only the loopback (newt) and the tailnet: the public domain
      # goes through newt, so arrives as 127.0.0.1; the phone as 100.64/10.
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

  # Public domain behind Zitadel SSO: the endpoint gives access to the agent
  # (tools, files), so never without authentication.
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
