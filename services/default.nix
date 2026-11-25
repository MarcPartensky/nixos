{
  pkgs,
  config,
  ...
}: {
  imports = [
    ./nextcloud
    ./cpu-priority
    ./postgres
    # Browser hook lab (BeEF): operator console on
    # beef.marcpartensky.com (Pangolin SSO), lure served by a fast Cloudflare
    # tunnel. The module carries the three units (filter, tunnel, beef) and the
    # Pangolin resource. See services/beef/default.nix.
    ./beef
    # The in-house MCP servers (shorturl, meetup, mac, roku...) are NOT
    # imported here: their code is mounted by modules/nixos/mcp-host from the
    # .py files, and their binary remains available as a flake output
    # (`nix build .#shorturl-mcp`). Keeping them as a module only added an
    # `environment.systemPackages` for them, hence a package evaluation at each host
    # eval for a binary that no one called anymore.
    # An in-house MCP still in stdio (shlink in Rust, arena-elo, username-recon,
    # share, tts) keeps its module: it is its mcpServers declaration that
    # makes it live.
    # Encrypted backups of tower (pqbox: ML-KEM-768): three tiers,
    # core timers (daily) and volume (weekly). Details in the module.
    ./backup-pqbox
    # ./vaultwarden  # NO: the vault no longer lives on tower or on the laptop.
    # Single source of truth = the anywhere VPS instance (anywhere profile
    # imports ../../services/vaultwarden), served by vault.marcpartensky.com
    # since 14/11/2026 (Pangolin target = site "rack", 127.0.0.1:8222).
    # This module being shared, it ran one instance per host and a
    # laptop rebuild recreated a third empty DB. tower keeps the
    # secret of the agent's technical account (services/hermes) for vault-get.sh.
    # The local tower DBs are kept read-only: vw_old_* on the
    # VPS and tower's old DB (to be deleted after verification).
    ./newt
    # thClaws: agent harness in Rust (webapp + CLI), package of the project flake
    # /home/marc/git/thclaws, exposed on thclaws.marcpartensky.com via the
    # newt blueprint above (Pangolin SSO). State on disk, no DB.
    ./thclaws
    ./readarr
    ./radarr
    ./sonarr
    ./prowlarr
    ./flaresolverr
    ./qbittorrent
    ./rqbit
    ./autossh
    ./wayvnc
    ./cage-firefox
    ./cage-waydroid
    # ./dnscrypt
    ./adguard
    ./matrix
    ./matrix-whatsapp
    ./matrix-signal
    ./matrix-discord
    ./matrix-meta
    ./matrix-linkedin
    ./matrix-marc-agent
    # ./matrix-telegram # wait for api_id/api_hash from my.telegram.org
    ./navidrome
    ./aonsoku.nix
    ./jellyfin
    # Camera stream aggregator (tablet, phone...) and a multi-stream web page
    # on cam.marcpartensky.com. See services/go2rtc/default.nix.
    ./go2rtc
    # Documentation platform comparison (5 static generators +
    # Wiki.js 3 on wiki.marcpartensky.com, Zitadel OIDC).
    ./docs-compare
    ./audiobookshelf
    ./media
    ./arr-mcp
    ./tor
    # ./minio
    # ./jupyterhub  # HOST ONLY (tower): declares
    # jupyterhub/secret_token, absent from secrets/common.yml. Imported by
    # profiles/tower, same pattern as ./gotify and ./discord-bot.
    ./hermes
    ./hermes-webui
    # Desktop front served in a browser (the REAL Hermes Desktop renderer)
    # on hermes.marcpartensky.com. See services/hermes-webapp/default.nix:
    # replaces the third-party WebUI on this domain, which stays reachable on loopback.
    ./hermes-webapp
    ./hermes-dashboard
    ./hermes-mobile
    # REAL web terminal on terminal.marcpartensky.com (ttyd + persistent
    # zellij session, Pangolin SSO). It is this domain that served before the Hermes
    # admin panel, moved to dash.marcpartensky.com.
    ./terminal
    # ./discord-bot  # HOST ONLY (tower): the module has no enable
    # option, so importing it here activated it on ALL hosts that import
    # ./services (laptop, laptop-iso). But its discord_bot_env secret only exists
    # in secrets/tower.yml: the laptop build failed with
    # "sops-install-secrets: the key 'discord_bot_env' cannot be found".
    # Moved to profiles/tower/configuration.nix.
    # ./discord-hermes-bridge  # useless: only one gateway per host, the one of the
    # default profile already serves the discord-bridge profile (the unit made
    # a second gateway crash-loop, exit 75 "The host gateway already serves
    # profile 'discord-bridge'"). The Discord cog hits the multiplexed route
    # http://127.0.0.1:8642/p/discord-bridge/v1/chat/completions.
    ./eternal-terminal
    ./nextcloud-mcp
    ./mcp-lan-access
    ./amazon-mcp
    ./hinge-auto
    # ./stalwart-mcp  # imported by profiles/tower only (see the comment
    # in the module: on anywhere the sops key conflicts with services/stalwart)
    # ./gotify  # HOST ONLY (tower): declares the secret
    # gotify_admin_password, absent from secrets/common.yml (so from laptop, deck
    # and anywhere). Same pattern as ./discord-bot: imported by profiles/tower.
    # Gotify <-> Matrix bridge (room "🪽 Hermes"): relay gotify-matrix-relay
    # + provisioning of the Gotify tokens. The Matrix -> Gotify hook is
    # vendored in services/hermes/hooks. See the module for the E2EE pitfalls.
    ./gotify-matrix
    ./zitadel
    # ./zitadel-mcp  # FIXME: zitadel_mcp_env secret missing in zitadel.yml
    # ./roku
    # Dead module: its only content was `mcpServers.roku` in stdio, and
    # services/roku/ is read-only for the agent (mask r--), so it could
    # not be emptied. The server now lives in services/roku-mcp.py,
    # mounted by modules/nixos/mcp-host. To delete the day the ACL becomes
    # writable again; the import is commented out so it does not come back.
    ./codeberg-mcp
    ./ibkr-mcp
    # ./vaultwarden-mcp  # ready and tested (binary + wrapper + secret): to
    # uncomment during a rebuild where cutting hermes-agent is not a problem, since
    # adding an mcpServer regenerates hermes-config.yaml and restarts the gateway.
    # Meanwhile, access goes through ~/.hermes/scripts/vault-get.sh (bw CLI).
    ./gitea
    ./gitea-mcp
    ./openrouter-mcp
    ./reactive-resume
    ./open-notebook
    # Shlink: URL shortener (s.marcpartensky.com) + its hermes MCP.
    ./shlink
    # Shlink MCP server in Rust (stdio, mcp/shlink-mcp-rs): it is no longer
    # mounted by mcp-host, so its module must be imported for
    # mcpServers.shlink to exist.
    ./shlink-mcp
    # Shlink admin console (official PWA) on shlink.marcpartensky.com,
    # behind the Pangolin SSO.
    ./shlink-web-client
    # File sharing via short link: public Garage bucket exposed at
    # files.marcpartensky.com + `share` MCP (S3 -> Shlink -> x.gd facade).
    ./share-mcp
    # Arena Elo rankings (ex-LMArena) without auth, read from the public
    # dataset lmarena-ai/leaderboard-dataset (CC BY 4.0). hermes MCP "arena-elo".
    ./arena-elo-mcp
    # Garage: S3 for build artifacts (replaces rustfs, removed for its
    # idle CPU) + S3 MCP on the hermes side.
    ./garage
    # Phone photos (camera, WhatsApp, Messenger): tree on the
    # media dataset + S3 mirror in Garage, one bucket per source.
    ./photos
    ./anki-sync-server
    ./anki-mcp
    # Winnie is NO LONGER in the host config (marc's decision of 13/11): the module
    # read the project flake with `builtins.getFlake`, which forced Nix to
    # re-read and hash the 16 GB of its working tree (11.5 GB of */target/,
    # 72,570 files) at EACH evaluation: tower eval measured at 863 s.
    # It is also this getFlake, and it alone, that made --impure mandatory.
    #
    # Warning: a switch starting from this state REMOVES the winnie units
    # (backend, front, dev, ingest, schema, bucket, jwt-secret) and its
    # Postgres provisioning. Winnie must therefore be redeployed outside the host
    # config BEFORE the next switch (same scheme as deploy/containers.nix).
    # ./winnie
    ./wise-mcp
    ./bank-mcp
    # Account enumeration by username / email (sherlock + maigret +
    # socialscan) with negative control: hermes MCP "username-recon".
    ./sherlock-mcp
    ./llm-steamdeck
    ./android-capture
    # The only door to root for the agent: PAM password or WebAuthn passkey,
    # first valid proof wins, everything is audited. See services/hermes-broker.
    ./hermes-broker
    # ./kanidm
    # ./syncserver
    # ./newt # wait for flakes update

    # Remote desktop gateway & access (WIP, not enabled on any profile: the
    # modules only define the options, `enable` stays false everywhere.
    # Domains/secrets still placeholders in the modules, cf. internal TODOs.)
    ../modules/nixos/vault-rustguac
    ../modules/nixos/rustguac
    ../modules/nixos/kasmvnc
    ../modules/nixos/kasmvnc-chrome-cdp.nix
    ../modules/nixos/rustdesk
    ../modules/nixos/nginx/rustguac
    ../modules/nixos/nginx/kasmvnc
    # Local vhost that injects the Catppuccin theme into the AdGuard UI (the
    # resolver only listens on loopback: it is the only themed access, mesh
    # included).
    ../modules/nixos/nginx/adguard-theme
  ];
}
