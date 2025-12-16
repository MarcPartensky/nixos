{ pkgs, config, ... } :
{
    imports = [
        # ./nextcloud
        ./postgres
        ./vaultwarden
        ./radarr
        ./sonarr
        ./prowlarr
        ./qbittorrent
        # ./newt # attendre maj flakes
    ];
}
