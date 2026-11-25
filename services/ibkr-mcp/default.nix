# services/ibkr-mcp/default.nix
# Interactive Brokers MCP server in READ-ONLY, backed by the Flex Web Service
# (HTTPS, no IBKR session, no 2FA, no local gateway to run).
#
# Scope: positions, balances, NAV, transactions, accounts. The reports are
# generated on demand (a few seconds of latency), so no real-time
# quote nor order book. For real time an IB
# Gateway local (TWS socket 4001) driven by IBC would be needed: out of scope here, see
# the note at the bottom of the file.
#
# One-time human actions required (Client Portal, login mandatory):
#  1. Performance & Reports > Flex Queries > Flex Web Service Configuration:
#     check Flex Web Service Status, Save, then Generate New Token (validity
#     up to 1 year; leave the IP field empty, the home IP changes).
#  2. Performance & Reports > Flex Queries > create an *Activity Flex Query*
#     with at least: Account Information, Open Positions, Cash Report,
#     Net Asset Value (NAV) in Base, Trades. Note the identifiers (Query ID).
#  3. Put the token + identifiers in secrets/ibkr.yml (see the placeholder
#     below), then re-activate: anything not yet filled in stays
#     in explicit error on the `status` tool side.
#
# The Flex token is INDEPENDENT of the IBKR password and revocable from the
# portal: the server holds no account credentials, therefore no
# power to place an order.
{self, pkgs, config, ...}: let
  # Binary built as a flake output (mcp/default.nix): buildable
  # without evaluating this conf, and no longer rebuilt on every host eval.
  ibkr-mcp = self.packages.${pkgs.stdenv.hostPlatform.system}.ibkr-mcp;
in {
  # Dotenv generated from sops and re-read on each call by the server: neither the
  # token nor the query identifiers are in the nix store (the module's `env`
  # are world-readable in the closure, so never a secret here).
  sops.templates."ibkr-flex.env" = {
    content = ''
      IBKR_FLEX_TOKEN=${config.sops.placeholder."ibkr/flex_token"}
      IBKR_FLEX_QUERY_ID=${config.sops.placeholder."ibkr/flex_query_id"}
      IBKR_FLEX_TRADES_QUERY_ID=${config.sops.placeholder."ibkr/flex_trades_query_id"}
    '';
    owner = "hermes";
    mode = "0400";
  };

  # TODO(marc): replace the 3 values of secrets/ibkr.yml (still
  # placeholders today) with the real token and Query IDs, otherwise the
  # server is deployed but inert: the tools exist and fail with
  # "placeholder" on each call. Check with the `status` tool.
  sops.secrets."ibkr/flex_token" = {
    key = "flex_token";
    sopsFile = ../../secrets/ibkr.yml;
    owner = "hermes";
  };
  sops.secrets."ibkr/flex_query_id" = {
    key = "flex_query_id";
    sopsFile = ../../secrets/ibkr.yml;
    owner = "hermes";
  };
  sops.secrets."ibkr/flex_trades_query_id" = {
    key = "flex_trades_query_id";
    sopsFile = ../../secrets/ibkr.yml;
    owner = "hermes";
  };

  # On the PATH to be able to probe the server by hand (stdio).
  environment.systemPackages = [ibkr-mcp];

}

# Phase 2 (not done): real time + order book. Requires IB Gateway (package
# absent from nixpkgs: IBKR download to pin), a virtual X (xvfb),
# Java, an IBKR account whose credentials live in a file, and a
# 2FA validation on phone every Sunday after 01:00 ET (IBKR
# imposes it at the account level, IBC does not bypass it; IBC is besides
# announced deprecated since September 2026, replacement = ibg-controller). Only
# do it if the need for live quotes is real.
