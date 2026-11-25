# Noms PUBLICS servis par le proxy interne de tower avec un certificat
# Let's Encrypt : `<hote> = "<nom court du backend>"`.
#
# Pourquoi un domaine public alors que le nom ne sert que dans le tailnet :
# aucun CA public ne signe un nom a label unique (`jellyfin`), et Let's Encrypt
# exige un domaine reel pour DNS-01. L'interet est la CONFIANCE : un certificat
# public est accepte par tout appareil (Mac, Android et son app Jellyfin, TV)
# sans installer de racine privee.
#
# La RESOLUTION reste celle du tailnet : le nom n'existe que dans le DNS interne
# (rewrites AdGuard des deux instances, plus /etc/hosts des postes macOS et
# NixOS). Aucun enregistrement public ne pointe vers l'IP mesh, donc rien de ce
# reseau n'apparait dans une zone publique.
{
  "jf.marcpartensky.com" = "jellyfin";
}
