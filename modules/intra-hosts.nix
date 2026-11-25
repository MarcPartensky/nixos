# Single source of truth for the short names served by the internal TLS proxy
# on tower (services/traefik-intra): `https://<name>` and
# `<name>.intra.marcpartensky.com`, reachable from the tailnet only.
#
# Consumed twice:
#   - services/traefik-intra: router, internal-CA leaf, /etc/hosts entry;
#   - services/adguard/tailnet.nix: DNS rewrite, for clients that query AdGuard
#     directly (Android has no /etc/hosts, macOS keeps a manual resolver).
#
# Every name resolves to the proxy (100.64.0.3). The value is the backend the
# proxy forwards to, so a service living on another mesh node is fine.
{
  mesh = "http://127.0.0.1:9140";
  # Moshi (full duplex) runs on the Mac, inside the tailnet: 100.64.0.5.
  # It must listen on 0.0.0.0 (or the tailnet address), not only 127.0.0.1.
  voice = "http://100.64.0.5:8998";
  # Jellyfin over the mesh instead of the public path, which goes
  # tower -> home uplink -> Chicago VPS (Pangolin/newt) -> back to tower.
  jellyfin = "http://127.0.0.1:8096";
  # mnemo (moteur de retention) : pod k3s en hostNetwork sur tower, lie a la
  # loopback, donc joignable par ce proxy mais par personne d'autre. Donne
  # `https://mnemo` et `https://mnemo.intra.marcpartensky.com` depuis le
  # tailnet, a cote du nom public mnemo.marcpartensky.com qui passe par
  # Pangolin avec le SSO.
  mnemo = "http://127.0.0.1:9152";
}
