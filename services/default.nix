{ pkgs, config, ... } :
{
    imports = [
        # ./nextcloud
        ./postgres
        ./vaultwarden
        ./radarr
        ./qbittorrent
        # ./newt # attendre maj flakes
    ];
}
