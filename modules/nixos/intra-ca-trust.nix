# Trust for the tailnet internal CA (modules/nixos/intra-ca).
#
# The short names served by the internal TLS proxy on tower (`https://mesh`,
# `https://jellyfin`) are signed by a private CA: no public CA can issue a
# single-label name. The root certificate below is PUBLIC (it sits in the
# repository); its private key exists on no machine of this flake.
#
# Import this module on every client that should accept those names. Without
# it curl/Safari answer `unable to get local issuer certificate` (tls=20) while
# the FQDN variant `<name>.intra.marcpartensky.com` keeps working, since that
# one carries a publicly trusted Let's Encrypt certificate.
{ ... }:
{
  security.pki.certificateFiles = [ ../../certs/intra-ca-root.crt ];
}
