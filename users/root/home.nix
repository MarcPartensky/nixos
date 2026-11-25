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

  # Identites ssh de root, pour le nix-daemon (qui tourne en root) : les builds
  # distribues sont lances par le daemon, et Nix ne transmet PAS la cle declaree
  # dans /etc/nix/machines a ssh. Sans identite utilisable, le daemon echoue sur
  # `no such identity: /root/.ssh/id_ed25519` puis `Permission denied` et
  # recompile en local sur tower (constate le 25/11/2026).
  #
  # La valeur va dans le bloc `*` (et pas dans un bloc par hote) : ssh applique
  # la PREMIERE valeur obtenue d'une directive, et modules/home/ssh declare deja
  # IdentityFile dans `*`. mkForce remplace cette valeur par la liste, essayee
  # dans l'ordre :
  #   - nix-builder          : paire DEDIEE hermes@tower -> builders, autorisee
  #     de facon declarative cote laptop et deck ;
  #   - id_ed25519 (hermes)  : la cle personnelle de l'agent, deja autorisee sur
  #     les deux builders (authorized_keys.d) : filet de securite si la paire
  #     dediee n'est pas encore posee sur un hote ;
  #   - ~/.ssh/id_ed25519    : cle personnelle de root (celle que le module pose).
  programs.ssh.settings."*".IdentityFile = lib.mkForce [
    "/var/lib/hermes/.ssh/nix-builder"
    "/var/lib/hermes/.ssh/id_ed25519"
    "~/.ssh/id_ed25519"
  ];
}
