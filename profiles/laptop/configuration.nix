{inputs, ...}: {
  imports = [
    ../../hosts/laptop/disko.nix
    ../../hosts/laptop/hardware-configuration.nix
    # Serveur MCP de synthese vocale (Phonon, Kokoro, OmniVoice, Ming,
    # Chatterbox, Breeze) : les moteurs, les poids et la RTX 3060 sont sur le
    # portable, donc toute generation de voix passe par lui. L'agent de tower
    # s'y connecte en HTTP sur le tailnet (100.64.0.4:8092/mcp) ; le port n'est
    # ouvert que sur tailscale0.
    ../../services/tts-mcp
  ];

  # Serveur MCP voix : les moteurs vivent dans le banc d'essai ~/tts-bench
  # (venvs pip, poids deja telecharges) et le worker tourne DANS l'interpreteur
  # de chaque moteur. Phonon et Kokoro sont CPU, les quatre autres prennent la
  # 3060, partagee avec llama-swap (d'ou le rapport de VRAM dans `status`).
  services.tts-mcp.enable = true;

  # sops.defaultSopsFile = ../../secrets/laptop.yml;

  # ========================================================================
  # VEILLE COUPEE : le portable sert de noeud de rendu (TTS GPU, podcasts)
  # et de worker Windmill ; une veille en plein job tue le travail en cours
  # (session ssh perdue, wav absent, log muet, rien dans le log).
  #
  # `AllowSuspend = false` ne suffit PAS : les cibles systemd restent
  # `linked` et `systemctl suspend` passe encore. Les masquer (symlink vers
  # /dev/null) est ce qui bloque reellement.
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

  # logind : plus rien ne declenche de veille, capot compris. Les Handle*
  # ne sont relus qu'au redemarrage de logind, mais les cibles masquees
  # suffisent deja : ne pas redemarrer logind a distance.
  services.logind.settings.Login = {
    IdleAction = "ignore";
    HandleLidSwitch = "ignore";
    HandleLidSwitchDocked = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandleSuspendKey = "ignore";
    HandleHibernateKey = "ignore";
    HandlePowerKey = "poweroff"; # appui court : extinction propre (defaut)
    HandlePowerKeyLongPress = "poweroff";
  };

  # Le powersave wifi suffit a couper une session ssh en plein rendu.
  networking.networkmanager.wifi.powersave = false;
}
