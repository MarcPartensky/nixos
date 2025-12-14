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
  environment.etc."nextcloud-password".mode = "0600";
  environment.systemPackages = with pkgs; [
    minio-client
    nextcloud32
  ];

  services.nextcloud = {
    enable = true;
    package = pkgs.nextcloud32;
    hostName = "localhost:8081";
    autoUpdateApps.enable = true;
    appstoreEnable = true;
    config = {
        dbtype = "pgsql";
        dbuser = "nextcloud";
        dbhost = "localhost:5432";
        dbpassFile = "/etc/nextcloud-password";
        adminuser = "root";
        adminpassFile = "/etc/nextcloud-password";
    };
    # extraApps = {
    #   inherit (config.services.nextcloud.package.packages.apps) news contacts
    #   calendar tasks deck;
    # };
    # extraAppsEnable = true;
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

  services.postgresql = {
    ensureDatabases = [ "nextcloud" ];
    ensureUsers = [
      {
        name = "nextcloud";
        ensureDBOwnership = true;
        # Since you use 'trust' in authentication below, we don't strictly need a password here
        # provided Nextcloud connects from localhost.
      }
    ];
  };

  # services.minio = {
  #   enable = true;
  #   listenAddress = "127.0.0.1:9000";
  #   consoleAddress = "127.0.0.1:9001";
  #   inherit rootCredentialsFile;
  # };


}
