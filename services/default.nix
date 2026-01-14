{ pkgs, config, ... } :
{
    imports = [
        ./nextcloud
        ./postgres
        ./vaultwarden
        ./newt
        ./readarr
        ./radarr
        ./sonarr
        ./prowlarr
        ./qbittorrent
        ./dnscrypt
        ./adguard
        ./navidrome
        ./tor
        # ./syncserver
        # ./newt # attendre maj flakes
    ];
}
