{inputs, config, lib, pkgs, ...}: {
  imports = [
    ../../hosts/laptop/disko.nix
    ../../hosts/laptop/hardware-configuration.nix
    # Voice synthesis MCP server (Phonon, Kokoro, OmniVoice, Ming,
    # Chatterbox, Breeze): the engines, the weights and the RTX 3060 are on the
    # laptop, so all voice generation goes through it. tower's agent
    # connects to it over HTTP on the tailnet (100.64.0.4:8092/mcp); the port is
    # open only on tailscale0.
    ../../services/tts-mcp

    # Local LLM providers consumed by Hermes from tower (custom_providers
    # laptop-llama :8080 and laptop-abl :8083). The llm-server system module
    # had disappeared from the repo (the unit was still running from /nix/store): it is
    # rewritten here. The model yaml stays /var/lib/llm-server/llama-swap.yaml,
    # editable without a rebuild; 8083 is a hermes user unit.
    ../../services/llm-server

    # pqbox backups (default producer: see the block below).
    ../../services/backup-pqbox

    # Hermes fallback: state copy from tower, automatic failover, and
    # publication of the fallback gateway on the tailnet (cf. block below).
    ../../services/hermes-fallback

    # Immich machine learning on the 3060: tower has no GPU and the nixpkgs
    # package is CPU-only, so we recompile onnxruntime with CUDA here (see the
    # module for the override chain). The Immich server stays on tower and
    # comes to fetch the embeddings on 100.64.0.4:3003.
    ../../services/immich-ml
  ];

  # Voice MCP server: the engines live in the ~/tts-bench test bench
  # (pip venvs, weights already downloaded) and the worker runs IN the interpreter
  # of each engine. Phonon and Kokoro are CPU, the other four take the
  # 3060, shared with llama-swap (hence the VRAM report in `status`).
  services.tts-mcp.enable = true;

  # OpenAI-compatible facade on 8093: this is what Open Notebook consumes
  # (credential "laptop-tts", base_url http://100.64.0.4:8093/v1). Before the
  # first switch that enables this option, stop the provisional user unit:
  #   systemctl --user disable --now tts-openai.service
  # otherwise the two processes fight over the port.
  services.tts-mcp.openaiBridge.enable = true;

  services.llm-server.enable = true;

  services.immich-ml.enable = true;

  # ========================================================================
  # pqbox BACKUPS: it is the LAPTOP that produces them by default.
  # The PostgreSQL dump and the Hermes state stay on tower, but the
  # expensive work (zstd -19 --long=27 on ~1 GB, then ML-KEM encryption) runs here:
  # 12 threads idle, 208 GB free, on permanently (uptime 4 d measured
  # on 14/11/2026), while tower is at 26 load with marc on it.
  # The transfer goes through SSH (paramiko) in streaming: tower's PostgreSQL
  # is not exposed on the network, its pg_hba refuses everything outside 127.0.0.1.
  # Tower keeps a run at 05:00 that does nothing if an archive of less than
  # 4 h already exists (services.backup-pqbox.skipIfFresh there).
  # Prerequisites verified on 14/11/2026: key ~hermes/.ssh/id_ed25519 of the laptop
  # authorized on tower (and /var/lib/hermes of tower at 2755, sshd StrictModes
  # refused the key as long as the home was group-writable).
  # ========================================================================
  services.backup-pqbox = {
    enable = true;
    pgRemoteHost = "tower";
    stateRemoteHost = "tower";
    coeurAt = "*-*-* 03:10:00";
  };

  # AdGuard is NOT imported on the laptop (services/laptop.nix does not import
  # ./adguard): nothing listens on 53 and the module only added one
  # more sops manifest. Resolution goes through the VPS. Settings kept
  # as a comment for the day the module comes back.
  # services.dnsFilter.bindHosts = [ "127.0.0.1" "100.64.0.4" ];

  # sops.defaultSopsFile = ../../secrets/laptop.yml;

  # ========================================================================
  # SLEEP CUT: the laptop serves as a render node (GPU TTS, podcasts)
  # and Windmill worker; a sleep mid-job kills the work in progress
  # (ssh session lost, wav missing, log mute, nothing in the log).
  #
  # `AllowSuspend = false` is NOT enough: the systemd targets stay
  # `linked` and `systemctl suspend` still goes through. Masking them (symlink to
  # /dev/null) is what really blocks it.
  # ========================================================================
  systemd.sleep.settings.Sleep = {
    AllowSuspend = false;
    AllowHibernation = false;
    AllowHybridSleep = false;
    AllowSuspendThenHibernate = false;
  };
  systemd.targets.sleep.enable = false;
  systemd.targets.suspend.enable = false;
  systemd.targets.hibernate.enable = false;
  systemd.targets.hybrid-sleep.enable = false;
  systemd.targets.suspend-then-hibernate.enable = false;

  # logind: nothing triggers sleep anymore, lid included. The Handle*
  # are only re-read at a logind restart, but the masked targets
  # are already enough: do not restart logind remotely.
  services.logind.settings.Login = {
    IdleAction = "ignore";
    HandleLidSwitch = "ignore";
    HandleLidSwitchDocked = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandleSuspendKey = "ignore";
    HandleHibernateKey = "ignore";
    HandlePowerKey = "poweroff"; # short press: clean shutdown (default)
    HandlePowerKeyLongPress = "poweroff";
  };

  # Wifi powersave is enough to cut an ssh session mid-render.
  networking.networkmanager.wifi.powersave = false;

  # ========================================================================
  # HERMES FALLBACK: the laptop is the second host able to serve the agent
  # when tower is unreachable. The gateway is INSTALLED but stopped at boot
  # (empty wantedBy); services/hermes-fallback copies tower's state every
  # night, probes tower every 60 s and starts the gateway after 5 min without
  # response, then publishes it on the tailnet (nginx 9124 -> gateway 9123).
  # The VPS remains the other source of truth: it does not serve as fallback.
  # ========================================================================
  services.hermes.enableAgent = true;
  services.hermesFallback.enable = true;

  # Installed but not started: the watchdog starts it, or marc.
  systemd.services.hermes-agent.wantedBy = lib.mkForce [];

  # secrets/hermes-gemini.yml only has tower's age key as recipient:
  # declaring it here would make setupSecrets fail and thus the WHOLE activation.
  # The gemini provider therefore stays inactive on the fallback (deepseek by default).
  services.hermes.enableGeminiToken = false;

  # The Matrix token is single-host for a material reason: two gateways
  # connected with the same token fight over the connection and the
  # E2EE sessions diverge. The fallback speaks via the webapp and the API, not via Element.
  services.hermes.enableMatrixToken = false;

  # The mem0 embeddings run on the 3060 shared with tts-mcp and
  # llama-swap (6 GB): on the fallback, nomic-embed-text goes to CPU (137 M
  # parameters, invisible in use) rather than risk a GPU OOM.
  # nixpkgs 26.05 removed services.ollama.acceleration: it is the PACKAGE that
  # chooses the backend (ollama-cpu instead of ollama-cuda).
  services.ollama.package = lib.mkForce pkgs.ollama-cpu;
}
