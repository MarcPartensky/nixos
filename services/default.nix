{ pkgs, config, ... } :
{
    imports = [
        # ./nextcloud
        ./postgres
        ./vaultwarden
        ./newt
        # ./nextcloud
        ./readarr
        ./radarr
        ./sonarr
        ./prowlarr
        ./qbittorrent
        ./dnscrypt
        ./adguard
        # ./syncserver
        # ./newt # attendre maj flakes
    ];
}
