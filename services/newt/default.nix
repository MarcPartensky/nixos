{ config, lib, pkgs, ... }:

let
  # Chemin sécurisé pour stocker les secrets (hors du store Nix)
  newtSecrets = "/etc/nixos/secrets/newt.env";
in
{
  # Activation du service Newt
  services.newt = {
    enable = true;
    
    # Optionnel : définir l'ID et l'endpoint ici ou dans le fichier secrets
    # id = "votre-id-pangolin";
    # endpoint = "https://votre.domaine.pangolin";
    
    logLevel = "INFO";
    environmentFile = newtSecrets;
  };

  # Création du fichier de secrets (à remplir manuellement)
  system.activationScripts.newtSecrets = ''
    if ! [ -f "${newtSecrets}" ]; then
      echo "Création du fichier de secrets Newt..."
      install -D -m 600 /dev/null "${newtSecrets}"
      cat > "${newtSecrets}" <<EOF
    # Remplacer avec vos informations Pangolin
    NEWT_ID=3r6f3e30gcrbxyr
    NEWT_SECRET=8r0igq7fqkrth6qmsqntf7v5llhfs3528f7hg530b1etzrol
    # Optionnel : décommentez si non défini dans la config
    # NEWT_ENDPOINT=https://pangolin.marcpartensky.com
    EOF
    fi
  '';

  # Installation du paquet newt-go
  environment.systemPackages = [ pkgs.newt-go ];

  # Politique de sécurité renforcée pour le service
  systemd.services.newt.serviceConfig = {
    RestrictAddressFamilies = lib.mkForce [ "AF_INET" "AF_INET6" "AF_UNIX" ];
    SystemCallFilter = lib.mkForce [ "~@clock" "~@debug" "~@module" "~@mount" "~@raw-io" "~@reboot" "~@swap" "~@privileged" ];
  };
}
