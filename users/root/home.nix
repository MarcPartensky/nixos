{inputs, lib, ...}: {
  home.stateVersion = "25.11";
  imports = [
    inputs.nixvim.homeModules.default
    ../../modules/home/neovim
    ../../modules/home/zsh
    ../../modules/home/git
    ../../modules/home/ssh
    ../../modules/home/gh
  ];

  # root's ssh identities, for the nix-daemon (which runs as root): distributed
  # builds are launched by the daemon, and Nix does NOT pass the key declared in
  # /etc/nix/machines to ssh. Without a usable identity the daemon fails with
  # `no such identity: /root/.ssh/id_ed25519` then `Permission denied` and
  # recompiles locally on tower (observed on 2026-11-25).
  #
  # The value goes into the `*` block (not a per-host block): ssh applies the
  # FIRST value obtained for a directive, and modules/home/ssh already declares
  # IdentityFile in `*`. mkForce replaces that value with the list, tried in
  # order:
  #   - nix-builder         : pair DEDICATED to hermes@tower -> builders,
  #     authorized declaratively on the laptop and the deck;
  #   - id_ed25519 (hermes) : the agent's personal key, already authorized on
  #     both builders (authorized_keys.d): safety net when the dedicated pair is
  #     not in place yet on a host;
  #   - ~/.ssh/id_ed25519   : root's personal key (the one the module sets).
  programs.ssh.settings."*".IdentityFile = lib.mkForce [
    "/var/lib/hermes/.ssh/nix-builder"
    "/var/lib/hermes/.ssh/id_ed25519"
    "~/.ssh/id_ed25519"
  ];
}
