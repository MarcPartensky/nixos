# PUBLIC names served by tower's internal proxy with a Let's Encrypt
# certificate: `<host> = "<backend short name>"`.
#
# Why a public domain when the name is only used in the tailnet:
# no public CA signs a single-label name (`jellyfin`), and Let's Encrypt
# requires a real domain for DNS-01. The interest is TRUST: a public certificate
# is accepted by any device (Mac, Android and its Jellyfin app, TV)
# without installing a private root.
#
# The RESOLUTION remains that of the tailnet: the name only exists in the internal DNS
# (AdGuard rewrites of the two instances, plus /etc/hosts of the macOS and
# NixOS machines). No public record points to the mesh IP, so nothing of this
# network appears in a public zone.
{
  "jf.marcpartensky.com" = "jellyfin";
}
