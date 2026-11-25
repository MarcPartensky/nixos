{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: {
  sops.secrets.newt_env = {
    sopsFile = ../../secrets/common.yml;
    mode = "0440";
  };

  services.newt = {
    enable = true;

    # newt 1.17 (input unstable) reports the local endpoints to the server
    # ("same network" detection of Pangolin 1.21: a client on the same LAN
    # goes direct) and accepts WireGuard clients by default
    # (the old --accept-clients flag no longer exists; --disable-clients
    # allows refusing). The 26.05 pin (newt 1.12.4) does not know how to do that.
    package = inputs.unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.fosrl-newt;

    environmentFile = config.sops.secrets.newt_env.path;

    # Winnie public resource: Svelte 5 front (static build served by
    # winnie-frontend.service on 127.0.0.1:8888). The public domain serves the
    # front; the backend is on api.*. The port must be that of the local
    # service (8888): on 8080 the proxy answers 502 (measured on 09/10/2026).
    blueprint.proxy-resources.winnie-frontend = {
      name = "winnie-frontend";
      protocol = "http";
      full-domain = "winnie.marcpartensky.com";
      auth.sso-enabled = false;
      targets = [
        {
          hostname = "127.0.0.1";
          port = 8888;
          method = "http";
        }
      ];
    };

    # Vite dev server of the app (port 8080): it is the URL the debug APK
    # loads (`tauri android dev`) and the phone browser for live
    # reload. The prod resource `winnie.marcpartensky.com` stays on 8888
    # (static dist): here the port is that of the dev server, so the domain
    # answers 502 when `npm run dev` is not running.
    # SSO disabled: the Tauri WebView should follow a login redirect.
    # The dev server already refuses /@fs/ on .keys/ (APK signing key), see
    # app/vite.config.ts.
    blueprint.proxy-resources.winnie-dev = {
      name = "winnie-dev";
      protocol = "http";
      full-domain = "dev.winnie.marcpartensky.com";
      auth.sso-enabled = false;
      targets = [
        {
          hostname = "127.0.0.1";
          port = 8080;
          method = "http";
        }
      ];
    };

    # Pangolin public resource: tower's noVNC client (wayvnc + websockify,
    # cf. modules/home/wayvnc). HTTP + SSO, so no newt version constraint
    # (Pangolin's native VNC mode would require newt > 1.13, and tower is on
    # 1.12.4; in HTTP 1.12.4 is enough).
    #
    # Target 127.0.0.1:6080: newt runs on tower and resolves the target locally,
    # so the service stays bound on loopback and nothing is exposed on the LAN.
    # `site` is omitted on purpose: when the blueprint is applied by a
    # site, Pangolin automatically assigns the site that applies it.
    # NB: this VPS's Pangolin (old schema) expects the `proxy-resources` key
    # + the `protocol` field. `public-resources`/`mode` (current doc) are
    # SILENTLY ignored by the server -> resource never created, and
    # Traefik answers 404 on the domain. Verified on 26/09/2026.
    # Karaoke (repo /var/lib/hermes/workspace/karaoke): the domain serves the
    # Vite server (PWA dev, port 5199) which proxies /api, /auth and /media to
    # the Rust API on 8790. Pangolin SSO disabled: the site is public by
    # default, host authentication goes through Zitadel OIDC on the app side.
    blueprint.proxy-resources.karaoke = {
      name = "karaoke";
      protocol = "http";
      full-domain = "karaoke.marcpartensky.com";
      auth.sso-enabled = false;
      targets = [
        {
          hostname = "127.0.0.1";
          port = 5199;
          method = "http";
        }
      ];
    };

    # Winnie public resource (Rust/Axum backend, reverse proxy).
    blueprint.proxy-resources.winnie-backend = {
      name = "winnie-backend";
      protocol = "http";
      full-domain = "api.winnie.marcpartensky.com";
      auth.sso-enabled = false;  # the mobile app cannot follow an SSO redirect
      targets = [
        {
          hostname = "127.0.0.1";
          port = 8787;
          method = "http";
          healthcheck = {
            enabled = true;
            hostname = "127.0.0.1";
            port = 8787;
            path = "/healthz";
            scheme = "http";
            mode = "http";
            method = "GET";
            interval = 30;
            unhealthy-interval = 30;
            timeout = 5;
            healthy-threshold = 1;
            unhealthy-threshold = 3;
          };
        }
      ];
    };

    blueprint.proxy-resources.dioxus-frontend = {
      name = "dioxus-frontend";
      protocol = "http";
      full-domain = "dioxus.marcpartensky.com";
      auth.sso-enabled = false;
      targets = [
        {
          hostname = "127.0.0.1";
          port = 8888;
          method = "http";
        }
      ];
    };

    # typer.marcpartensky.com: typing practice (Rust server
    # typer-server of the typer flake, vendored under projects/typer, 127.0.0.1:9146).
    # SSO disabled: no personal
    # data, the scores stay in the browser's localStorage.
    #
    # Note (24/11/2026): the `typer` resource (id 103) had first been created
    # by the integration API to deploy without a rebuild; the blueprint does not
    # know how to adopt an existing resource (it attempts a creation, hits
    # "Resource already exists" and aborts the WHOLE blueprint silently). It
    # was deleted before the 24/11 switch: the blueprint recreates it from this
    # file. Same pitfall for any resource created by hand: delete it
    # before rebuilding, otherwise the OTHER resources of the blueprint stop being
    # updated.
    blueprint.proxy-resources.typer = {
      name = "typer";
      protocol = "http";
      full-domain = "typer.marcpartensky.com";
      auth.sso-enabled = false;
      targets = [
        {
          hostname = "127.0.0.1";
          port = 9146;
          method = "http";
          # Without a declared healthcheck, Pangolin probes /healthz, which typer-server
          # does not serve: the target would be marked unhealthy (measurement of 24/11:
          # "/" returns 200, "/healthz" 404). "/" is therefore the right probe.
          healthcheck = {
            enabled = true;
            hostname = "127.0.0.1";
            port = 9146;
            path = "/";
            scheme = "http";
            mode = "http";
            method = "GET";
            interval = 30;
            unhealthy-interval = 30;
            timeout = 5;
            healthy-threshold = 1;
            unhealthy-threshold = 3;
          };
        }
      ];
    };

    # mnemo.marcpartensky.com: retention engine (Rust binary of the
    # mnemo flake, vendored under projects/mnemo, in a k3s pod on 127.0.0.1:9152).
    # SSO ACTIVE: the explanation cards contain marc's
    # conversations, nothing must be readable without login. The service handles no
    # authentication itself (the pod runs with MNEMO_OPEN=1, port on
    # loopback): the Pangolin edge is the only door.
    blueprint.proxy-resources.mnemo = {
      name = "mnemo";
      protocol = "http";
      full-domain = "mnemo.marcpartensky.com";
      auth.sso-enabled = true;
      targets = [
        {
          hostname = "127.0.0.1";
          port = 9152;
          method = "http";
          # The service really serves /healthz (the pod has the same probe):
          # unlike typer, no need to probe "/".
          healthcheck = {
            enabled = true;
            hostname = "127.0.0.1";
            port = 9152;
            path = "/healthz";
            scheme = "http";
            mode = "http";
            method = "GET";
            interval = 30;
            unhealthy-interval = 30;
            timeout = 5;
            healthy-threshold = 1;
            unhealthy-threshold = 3;
          };
        }
      ];
    };

    # Legal pages (privacy + terms) required by Enable Banking for PRODUCTION
    # apps in restricted mode: two static files served by the `legal-pages`
    # unit (services/legal-pages), exposed WITHOUT SSO (the Enable Banking
    # review must reach them anonymously).
    blueprint.proxy-resources.legal-pages = {
      name = "legal-pages";
      protocol = "http";
      full-domain = "legal.marcpartensky.com";
      auth.sso-enabled = false;
      targets = [
        {
          hostname = "127.0.0.1";
          port = 8077;
          method = "http";
        }
      ];
    };

    blueprint.proxy-resources.novnc-tower = {
      name = "vnc";
      protocol = "http";
      full-domain = "vnc.marcpartensky.com";
      auth.sso-enabled = true;
      targets = [
        {
          hostname = "127.0.0.1";
          port = 6080;
          method = "http";
          # noVNC serves its client on /vnc.html: "/" answers 404 (measurement of
          # 28/09/2026), so a healthcheck on "/" would mark the target
          # unhealthy and Pangolin would take it out of the load-balancer.
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = 6080;
          path = "/vnc.html";
          scheme = "http";
          mode = "http";
          method = "GET";
          interval = 30;
          unhealthy-interval = 30;
          timeout = 5;
          healthy-threshold = 1;
          unhealthy-threshold = 3;
        };
        }
      ];
    };

    # noVNC client of the Android emulator (cage-waydroid): same scheme as
    # novnc-tower (proxy-resources + protocol, old schema of the VPS). HTTP + SSO,
    # no newt version constraint. Target 127.0.0.1:6082 (loopback: only
    # newt, which runs on tower, reaches it; nothing open on the LAN on this port).
    blueprint.proxy-resources.novnc-waydroid = {
      name = "android";
      protocol = "http";
      full-domain = "android.marcpartensky.com";
      auth.sso-enabled = true;
      targets = [
        {
          hostname = "127.0.0.1";
          port = 6082;
          method = "http";
          healthcheck = {
            enabled = true;
            hostname = "127.0.0.1";
            port = 6082;
            path = "/vnc.html";
            scheme = "http";
            mode = "http";
            method = "GET";
            interval = 30;
            unhealthy-interval = 30;
            timeout = 5;
            healthy-threshold = 1;
            unhealthy-threshold = 3;
          };
        }
      ];
    };

    # Wiki.js 3 (documentation platform comparison, cf.
    # services/docs-compare): podman container bound to 127.0.0.1:8916.
    # The only docs-compare resource exposed: the static builds of the five
    # generators (hub, mdbook, mkdocs, starlight, docusaurus, ref) were
    # erased from /var/lib/docs-compare and are to be regenerated outside Nix before
    # exposing their domains again.
    # Pangolin SSO disabled: auth is done INSIDE Wiki.js (local +
    # Zitadel OIDC strategies), a Pangolin redirect would short-circuit the app's
    # own login.
    blueprint.proxy-resources.docs-compare-wiki = {
      name = "docs-compare-wiki";
      protocol = "http";
      full-domain = "wiki.marcpartensky.com";
      auth.sso-enabled = false;
      targets = [
        {
          hostname = "127.0.0.1";
          port = 8916;
          method = "http";
        }
      ];
    };

    # Cameras (go2rtc, cf. services/go2rtc): one page, one button per stream.
    # SSO ACTIVE: go2rtc has no authentication of its own, so the public
    # resource would be a camera open to the world without this line. The
    # `skipToIdpId` field that sends directly to Zitadel does not exist in the
    # blueprint: if Pangolin shows its internal email/password form
    # instead of the Zitadel redirect, set the idp in the DB
    # (`UPDATE resources SET skipToIdpId=<id> WHERE niceId='cam'`) then
    # note it here. Loopback target 1984: go2rtc only listens on loopback, nothing
    # is exposed on the LAN.
    blueprint.proxy-resources.cam = {
      name = "cam";
      protocol = "http";
      full-domain = "cam.marcpartensky.com";
      auth.sso-enabled = true;
      targets = [
        {
          hostname = "127.0.0.1";
          port = 1984;
          method = "http";
        }
      ];
    };

    # thClaws (agent harness in Rust, services/thclaws): webapp on
    # 127.0.0.1:8453 on the newt side (thClaws binds 0.0.0.0 but the port is not
    # in allowedTCPPorts, so the LAN is closed; the tailnet goes through
    # the trusted interface).
    #
    # SSO ACTIVE: thClaws has no authentication of its own (measurement of
    # 13/11/2026: `GET /` returns 200 without a token even with THCLAWS_SERVE_TOKEN,
    # and the UI gives a full shell). As for cam, `skipToIdpId` does not exist
    # in the blueprint: if Pangolin shows its internal form instead
    # of redirecting to Zitadel, set the idp in the DB
    # (`UPDATE resources SET skipToIdpId=<id> WHERE niceId='thclaws'`).
    #
    # NOT VERIFIED: WebSocket traversal (chat + terminal) through
    # badger/forward-auth. If the chat stays mute behind the public domain,
    # that is it, not Traefik nor the certificate: the tailnet (100.64.0.3:8453)
    # remains the fallback path that does not go through the proxy.
    blueprint.proxy-resources.thclaws = {
      name = "thclaws";
      protocol = "http";
      full-domain = "thclaws.marcpartensky.com";
      auth.sso-enabled = true;
      targets = [
        {
          hostname = "127.0.0.1";
          port = 8453;
          method = "http";
          healthcheck = {
            enabled = true;
            hostname = "127.0.0.1";
            port = 8453;
            path = "/";
            scheme = "http";
            mode = "http";
            method = "GET";
            interval = 30;
            unhealthy-interval = 30;
            timeout = 5;
            healthy-threshold = 1;
            unhealthy-threshold = 3;
          };
        }
      ];
    };

  };

  # systemd.services.newt.serviceConfig = {
  #   DynamicUser = lib.mkForce false;
  #   PrivateUsers = lib.mkForce false;
  #   ProtectHome = lib.mkForce false;
  #   ExecStart = lib.mkForce (pkgs.writeShellScript "newt-start" ''
  #     set -a
  #     source ${config.sops.secrets.newt_env.path}
  #     set +a
  #     exec ${pkgs.fosrl-newt}/bin/newt \
  #       -endpoint="$PANGOLIN_ENDPOINT" \
  #       -id="$NEWT_ID" \
  #       -secret="$NEWT_SECRET"
  #   '');
  # };
}
