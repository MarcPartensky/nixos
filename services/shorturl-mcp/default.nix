# services/shorturl-mcp/default.nix
# Serveur MCP `shorturl` pour hermes : raccourcisseurs PUBLICS ANONYMES a
# domaine de 4 caracteres (x.gd, v.gd, t.tl), code dans ./server.py.
#
# Pourquoi ces trois-la et pas un connecteur unique : aucun raccourcisseur
# public ne cumule anonymat, slug custom et fiabilite, donc le serveur expose
# une interface unique (shorturl_shorten / shorturl_expand / shorturl_history)
# et choisit le backend, avec repli automatique. Detail des criteres et des
# services ecartes (t.ly, s.ee, s.id, 0.gp et sa flotte a Turnstile, t.im,
# t.mr, l.tl, z.sh, d.to, t.co) dans l'entete de server.py.
#
# Aucun secret : ces services sont sans compte et sans captcha. Le seul etat
# local est le journal des creations (SHORTURL_STATE_DIR), sous le home de
# hermes, puisqu'aucun de ces services ne tient d'historique sans compte.
#
# Transport stdio : hermes spawn le subprocess. Debug a la main (garder stdin
# ouvert, un EOF tue la requete en vol) :
#   { printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n'; sleep 5; } \
#     | /nix/store/.../bin/shorturl-mcp
{self, pkgs, ...}: let
  # Binaire construit comme sortie du flake (mcp/default.nix) : buildable
  # sans evaluer cette conf, et plus reconstruit a chaque eval de l'hote.
  shorturl-mcp = self.packages.${pkgs.stdenv.hostPlatform.system}.shorturl-mcp;

in {
  # Le binaire sur le PATH, et reference par mcpServers.shorturl.command.
  environment.systemPackages = [shorturl-mcp];

}
