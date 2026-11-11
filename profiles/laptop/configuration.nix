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
}
