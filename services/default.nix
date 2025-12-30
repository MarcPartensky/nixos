{ pkgs, config, ... } :
{
    imports = [
        # ./nextcloud
        ./postgres
        ./vaultwarden
        # ./nextcloud
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
