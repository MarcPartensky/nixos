{ pkgs, config, ... }:
  let
  accessKey = "nextcloud";
  secretKey = "test12345";

  rootCredentialsFile = pkgs.writeText "minio-credentials-full" ''
    MINIO_ROOT_USER=nextcloud
    MINIO_ROOT_PASSWORD=test12345
  '';
in {
  environment.etc."nextcloud-password".text = "nextcloudpassword";

  services.nextcloud = {
    enable = true;
    package = pkgs.nextcloud31;
    hostName = "localhost";
    # config.dbtype = "sqlite";
    config = {
        dbtype = "pgsql";
        dbuser = "nextcloud";
        dbhost = "localhost:5432";
        dbpassFile = "/etc/nextcloud-password";
    # config.adminpassFile = "/etc/nextcloud-admin-pass";
    };
    extraApps = {
      inherit (config.services.nextcloud.package.packages.apps) news contacts
      calendar tasks deck;
    };
    extraAppsEnable = true;
    configureRedis = true;

    # config.objectstore.s3 = {
    #   enable = true;
    #   bucket = "nextcloud";
    #   verify_bucket_exists = true;
    #   key = accessKey;
    #   secretFile = "${pkgs.writeText "secret" "test12345"}";
    #   hostname = "localhost";
    #   useSsl = false;
    #   port = 9000;
    #   usePathStyle = true;
    #   region = "us-east-1";
    # };
  };

  # services.minio = {
  #   enable = true;
  #   listenAddress = "127.0.0.1:9000";
  #   consoleAddress = "127.0.0.1:9001";
  #   inherit rootCredentialsFile;
  # };

  environment.systemPackages = [ pkgs.minio-client ];
}
