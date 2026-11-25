# services/hermes-browser/bitwarden.nix
# CLI Bitwarden (`bw`) pour l'utilisateur hermes : Hermes le détecte tout seul
# sur son PATH (/etc/profiles/per-user/hermes/bin) et l'utilise comme backend
# « bitwarden » de browser_vault. Le mot de passe maître ne transite jamais
# par la conversation : Hermes le demande dans une invite masquée (bw unlock
# --passwordenv), le jeton de session reste en mémoire.
#
# - Serveur : https://vault.marcpartensky.com (Vaultwarden de tower). Le CLI
#   2026 refuse tout serveur en http, donc pas de 127.0.0.1:8222 direct ;
#   l'API doit être joignable sans le SSO Pangolin (règles de contournement
#   sur /api, /identity, /notifications de la ressource Pangolin).
# - Connexion initiale, une seule fois, par marc : `sudo -u hermes bw login`.
# - users.users.hermes.packages plutôt qu'environment.systemPackages : outil
#   propre à l'agent, et l'ajout ne redémarre pas hermes-agent.
{
  pkgs,
  ...
}: let
  server = "https://vault.marcpartensky.com";
  bw = "${pkgs.bitwarden-cli}/bin/bw";
in {
  users.users.hermes.packages = [pkgs.bitwarden-cli];

  # Pointe le CLI sur le bon serveur tant qu'aucun compte n'est connecté
  # (bw refuse de changer de serveur une fois loggué). Idempotent.
  systemd.services.hermes-bw-server = {
    description = "CLI bw de hermes pointé sur ${server}";
    wantedBy = ["multi-user.target"];
    environment.HOME = "/var/lib/hermes";
    serviceConfig = {
      Type = "oneshot";
      User = "hermes";
      RemainAfterExit = true;
    };
    script = ''
      status=$(${bw} status 2>/dev/null || true)
      cur=$(printf '%s' "$status" | ${pkgs.jq}/bin/jq -r '.serverUrl // empty' 2>/dev/null || true)
      st=$(printf '%s' "$status" | ${pkgs.jq}/bin/jq -r '.status // empty' 2>/dev/null || true)
      if [ "$cur" != "${server}" ] && [ "$st" != "locked" ] && [ "$st" != "unlocked" ]; then
        ${bw} config server "${server}" >/dev/null 2>&1 || true
      fi
    '';
  };
}
