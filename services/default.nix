{ pkgs, config, ... } :
{
    imports = [
        # ./nextcloud
        ./postgres
        ./vaultwarden
        ./radarr
        ./sonarr
        ./qbittorrent
        # ./newt # attendre maj flakes
    ];
}
