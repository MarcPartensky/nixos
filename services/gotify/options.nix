# services/gotify/options.nix
#
# HOME options of the services/gotify module, declared in a separate file:
# default.nix carries configuration attributes at the top level
# (sops, services, systemd), so it cannot also contain an
# `options` attribute (fatal error "has an unsupported attribute services").
#
# The module serves two opposite hosts: tower (newt, postgres cluster dedicated to
# gotify) and anywhere (Pangolin site `rack`, shared postgres cluster).
{ lib, ... }: {
  options.services.gotify.publishViaNewt = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Declares the Pangolin resource via the newt blueprint (host running newt).";
  };

  options.services.gotify.managePostgresAuth = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Enforces the gotify pg_hba rules (to be disabled on a shared postgres cluster).";
  };
}
