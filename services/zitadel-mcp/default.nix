# services/zitadel-mcp/default.nix
# Serveur MCP Zitadel pour hermes : création/gestion des comptes (humains) de
# ses potes via l'API Zitadel, transport stdio (hermes spawn le subprocess).
#
# Auth : Personal Access Token d'un service user Zitadel. Le token vit dans un
# fichier sops (secrets/zitadel.yml), jamais dans le nix store ; le serveur le
# lit à chaque appel.
#
# Créer le PAT dans la console (https://auth.marcpartensky.com) :
#   Users -> Service Users -> New (Access Token Type = Bearer)
#   puis Organisation ZITADEL -> Managers -> ajouter le service user
#   -> rôle ORG_OWNER (ou org user manager pour un scope plus étroit)
#   puis Service User -> Personal Access Tokens -> New, copier le token.
#
# Debug : tester le serveur à la main en tant que hermes
#   { printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n'; sleep 5; } \
#     | ZITADEL_PAT_FILE=... /nix/store/.../bin/zitadel-mcp
# (garder stdin ouvert : un EOF tue la requête en vol)
{pkgs, config, ...}: let
  zitadel-mcp =
    pkgs.writers.writePython3Bin "zitadel-mcp" {
      libraries = [pkgs.python3Packages.mcp];
      flakeIgnore = ["E501" "W503" "W504"];
    } ''
      import json
      import os
      import urllib.error
      import urllib.parse
      import urllib.request

      try:
          from mcp.server import MCPServer  # mcp >= 2
      except ImportError:
          from mcp.server.fastmcp import FastMCP as MCPServer  # mcp 1.x

      BASE = os.environ.get("ZITADEL_URL", "https://auth.marcpartensky.com").rstrip("/")
      ORG_ID = os.environ.get("ZITADEL_ORG_ID", "")  # optionnel : x-zitadel-orgid

      STATES = {
          0: "unspecified",
          1: "active",
          2: "inactive",
          3: "deleted",
          4: "locked",
          5: "suspend",
          6: "initial (invité, pas encore activé)",
      }

      mcp = MCPServer("zitadel")


      def _pat():
          path = os.environ.get("ZITADEL_PAT_FILE")
          if path and os.path.exists(path):
              with open(path) as fh:
                  return fh.read().strip()
          return os.environ.get("ZITADEL_PAT", "").strip()


      def api(method, path, body=None):
          """Appel API Zitadel. Lève RuntimeError avec le corps d'erreur brut."""
          token = _pat()
          if not token:
              raise RuntimeError(
                  "Aucun PAT Zitadel : renseigner ZITADEL_PAT_FILE (secret sops) "
                  "ou ZITADEL_PAT."
              )
          data = json.dumps(body).encode() if body is not None else None
          req = urllib.request.Request(BASE + path, data=data, method=method)
          req.add_header("Authorization", "Bearer " + token)
          req.add_header("Accept", "application/json")
          if data is not None:
              req.add_header("Content-Type", "application/json")
          if ORG_ID:
              req.add_header("x-zitadel-orgid", ORG_ID)
          try:
              with urllib.request.urlopen(req, timeout=30) as resp:
                  raw = resp.read().decode()
                  return resp.status, (json.loads(raw) if raw.strip() else {})
          except urllib.error.HTTPError as err:
              raw = err.read().decode()
              try:
                  detail = json.dumps(json.loads(raw), ensure_ascii=False)
              except Exception:
                  detail = raw
              raise RuntimeError(f"HTTP {err.code} sur {method} {path} : {detail[:900]}") from None


      def _view(user):
          """Réduit un UserView v1 aux champs utiles."""
          state = user.get("state")
          return {
              "id": user.get("id"),
              "login": user.get("preferredLoginName") or user.get("username"),
              "username": user.get("username"),
              "email": user.get("email"),
              "email_verified": user.get("isEmailVerified"),
              "nom": user.get("displayName"),
              "prenom": user.get("firstName"),
              "nom_famille": user.get("lastName"),
              "etat": STATES.get(state, state) if isinstance(state, int) else state,
              "type": user.get("type"),
              "derniere_connexion": user.get("lastLogin"),
              "creation": (user.get("details") or {}).get("creationDate"),
          }


      def _search_users(**kwargs):
          body = {"offset": 0, "limit": kwargs.pop("limit", 50)}
          queries = kwargs.pop("queries", None)
          if queries:
              body["queries"] = queries
          _, resp = api("POST", "/management/v1/users/_search", body)
          return resp


      @mcp.tool()
      def status() -> dict:
          """État de l'instance Zitadel et de l'authentification du serveur.

          Renvoie l'org courante et le nombre de comptes humains. Sert de test
          de vie du PAT (renvoie l'erreur HTTP brute si le token est invalide
          ou sans droits).
          """
          _, org = api("GET", "/management/v1/orgs/me")
          teams = _search_users(limit=1)
          return {
              "instance": BASE,
              "org": {
                  "id": (org.get("org") or {}).get("id"),
                  "nom": (org.get("org") or {}).get("name"),
                  "domaine": (org.get("org") or {}).get("primaryDomain"),
              },
              "comptes_humains": (teams.get("details") or {}).get("totalResult"),
          }


      @mcp.tool()
      def list_users(filtre: str = "", limit: int = 50) -> list:
          """Liste les comptes (humains et techniques) de l'org.

          filtre : sous-chaîne cherchée dans le login ou l'email (casse
          ignorée). Vide = tous.
          """
          users = (_search_users(limit=max(limit, 1)).get("result") or [])
          views = [_view(u) for u in users]
          if filtre:
              needle = filtre.lower()
              views = [
                  v
                  for v in views
                  if any(
                      needle in (v[champ] or "").lower()
                      for champ in ("login", "email", "nom")
                  )
              ]
          return views


      @mcp.tool()
      def find_user(email_ou_login: str) -> dict:
          """Trouve un compte par email ou login (égalité, casse ignorée)."""
          for query in (
              {"emailQuery": {"emailAddress": email_ou_login, "method": "TEXT_QUERY_METHOD_EQUALS_IGNORE_CASE"}},
              {"userNameQuery": {"userName": email_ou_login, "method": "TEXT_QUERY_METHOD_EQUALS_IGNORE_CASE"}},
          ):
              resp = _search_users(limit=5, queries=[query])
              found = resp.get("result") or []
              if found:
                  return _view(found[0])
          return {"trouve": False, "recherche": email_ou_login}


      @mcp.tool()
      def get_user(user_id: str) -> dict:
          """Détail complet d'un compte par son user_id (id technique Zitadel)."""
          _, resp = api("GET", f"/management/v1/users/{urllib.parse.quote(user_id)}")
          return _view(resp.get("user") or {})


      @mcp.tool()
      def create_friend(
          email: str,
          prenom: str,
          nom: str,
          username: str = "",
          envoyer_invitation: bool = True,
          mot_de_passe: str = "",
          langue: str = "fr",
      ) -> dict:
          """Crée un compte humain pour un pote et lui envoie l'invitation.

          Par défaut : email marqué vérifié (évite un second mail de
          vérification) puis envoi du mail d'invitation Zitadel ; le pote
          choisit lui-même son mot de passe/passkey, l'agent ne le voit jamais.
          Décocher envoyer_invitation n'a de sens que si mot_de_passe est
          fourni (compte utilisable tout de suite, mot de passe à transmettre
          hors ligne).
          """
          if not envoyer_invitation and not mot_de_passe:
              return {
                  "erreur": "sans invitation il faut fournir mot_de_passe, sinon "
                  "le compte reste en état initial et inutilisable"
              }
          body = {
              "username": username or email,
              "profile": {"givenName": prenom, "familyName": nom, "preferredLanguage": langue},
              "email": {"email": email, "isVerified": True},
          }
          if mot_de_passe:
              body["password"] = {"password": mot_de_passe, "changeRequired": False}
          _, created = api("POST", "/v2/users/human", body)
          user_id = created.get("userId")
          out = {"id": user_id, "email": email, "invitation": "non demandée"}
          if envoyer_invitation:
              _, invite = api(
                  "POST",
                  f"/v2/users/{urllib.parse.quote(user_id)}/invite_code",
                  {"sendCode": {}},
              )
              out["invitation"] = "mail envoyé"
          return out


      @mcp.tool()
      def invite_user(user_id: str) -> dict:
          """(Re)envoie le mail d'invitation à un compte existant, y compris un
          compte resté en état initial jamais activé. Écrase l'ancien code."""
          _, resp = api(
              "POST",
              f"/v2/users/{urllib.parse.quote(user_id)}/invite_code",
              {"sendCode": {}},
          )
          return {"ok": True, "details": resp.get("details")}


      @mcp.tool()
      def set_password(user_id: str, mot_de_passe: str, changement_obligatoire: bool = False) -> dict:
          """Fixe le mot de passe d'un compte (l'agent le voit passer : à
          réserver aux cas où l'invitation par mail ne convient pas)."""
          _, resp = api(
              "POST",
              f"/v2/users/{urllib.parse.quote(user_id)}/password",
              {
                  "newPassword": {
                      "password": mot_de_passe,
                      "changeRequired": changement_obligatoire,
                  },
                  "verification": {},
              },
          )
          return {"ok": True, "details": resp.get("details")}


      @mcp.tool()
      def reset_password(user_id: str) -> dict:
          """Envoie un mail de réinitialisation de mot de passe (le pote choisit
          lui-même le nouveau)."""
          _, resp = api(
              "POST",
              f"/v2/users/{urllib.parse.quote(user_id)}/password/reset",
              {"sendLink": {}},
          )
          return {"ok": True, "details": resp.get("details")}


      @mcp.tool()
      def set_active(user_id: str, actif: bool) -> dict:
          """Active ou désactive un compte. Désactivé = ne peut plus se
          connecter, données conservées. Réversible."""
          action = "reactivate" if actif else "deactivate"
          _, resp = api("POST", f"/v2/users/{urllib.parse.quote(user_id)}/{action}")
          return {"ok": True, "etat": "actif" if actif else "désactivé", "details": resp.get("details")}


      @mcp.tool()
      def delete_user(user_id: str) -> dict:
          """Supprime un compte (irréversible). Préférer set_active(False)."""
          api("DELETE", f"/v2/users/{urllib.parse.quote(user_id)}")
          return {"ok": True, "supprime": user_id}


      @mcp.tool()
      def list_projects() -> list:
          """Projets Zitadel de l'org (les applications à rôle, ex. Nextcloud,
          Portainer) : à croiser avec list_project_roles."""
          _, resp = api("POST", "/management/v1/projects/_search", {"offset": 0, "limit": 50})
          return [
              {"id": p.get("id"), "nom": p.get("name"), "etat": p.get("state")}
              for p in (resp.get("result") or [])
          ]


      @mcp.tool()
      def list_project_roles(project_id: str) -> list:
          """Rôles disponibles dans un projet (à passer à grant_roles)."""
          _, resp = api(
              "POST",
              f"/management/v1/projects/{urllib.parse.quote(project_id)}/roles/_search",
              {"offset": 0, "limit": 100},
          )
          return [
              {
                  "cle": r.get("key"),
                  "nom": r.get("displayName") or (r.get("details") or {}).get("displayName"),
                  "groupe": r.get("group"),
              }
              for r in (resp.get("result") or [])
          ]


      @mcp.tool()
      def grant_roles(user_id: str, project_id: str, roles: list[str]) -> dict:
          """Donne des rôles projet à un compte sur un projet (accès applicatif)."""
          _, resp = api(
              "POST",
              f"/management/v1/users/{urllib.parse.quote(user_id)}/grants",
              {"projectId": project_id, "roleKeys": roles},
          )
          return {"ok": True, "grant_id": resp.get("userGrantId"), "roles": roles}


      @mcp.tool()
      def list_user_grants(user_id: str) -> list:
          """Rôles projet déjà accordés à un compte."""
          _, resp = api("GET", f"/management/v1/users/{urllib.parse.quote(user_id)}/grants")
          out = []
          for g in resp.get("userGrantList") or resp.get("result") or []:
              out.append(
                  {
                      "grant_id": g.get("id"),
                      "projet": g.get("projectName") or g.get("projectId"),
                      "roles": g.get("roleKeys"),
                      "etat": g.get("state"),
                  }
              )
          return out


      @mcp.tool()
      def revoke_grant(user_id: str, grant_id: str) -> dict:
          """Retire un rôle projet (voir list_user_grants pour le grant_id)."""
          api(
              "DELETE",
              f"/management/v1/users/{urllib.parse.quote(user_id)}/grants/{urllib.parse.quote(grant_id)}",
          )
          return {"ok": True, "retire": grant_id}


      if __name__ == "__main__":
          mcp.run()
    '';
in {
  # Le PAT vit dans secrets/zitadel.yml (fichier sops distinct : tower.yml n'est
  # pas modifiable par hermes, sa clé MAC exigerait la clé age privée).
  sops.secrets."zitadel_mcp_pat" = {
    sopsFile = ../../secrets/zitadel.yml;
    owner = "hermes";
    group = "hermes";
    mode = "0400";
    restartUnits = ["hermes-agent.service"];
  };

  services.hermes-agent.mcpServers.zitadel = {
    command = "${zitadel-mcp}/bin/zitadel-mcp";
    env = {
      ZITADEL_URL = "https://auth.marcpartensky.com";
      ZITADEL_PAT_FILE = config.sops.secrets."zitadel_mcp_pat".path;
    };
  };
}