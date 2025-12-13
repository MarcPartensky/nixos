{ config, pkgs, ... }:
let
  sshdDirectory = "${config.user.home}/sshd";
  port = 8022;
  pubKeyPath = "${config.user.home}/sshd/ssh_key.pub";  # Replace with your key path
in
{
  # Generate keys and config on activation
  build.activation.sshd = ''
    mkdir -p "${config.user.home}/.ssh"
    cat ${pubKeyPath} > "${config.user.home}/.ssh/authorized_keys"
    
    if [ ! -d "${sshdDirectory}" ]; then
      mkdir -p "${sshdDirectory}"
      ${pkgs.openssh}/bin/ssh-keygen -t rsa -b 4096 -f "${sshdDirectory}/ssh_host_rsa_key" -N ""
      echo "HostKey ${sshdDirectory}/ssh_host_rsa_key\nPort ${toString port}" > "${sshdDirectory}/sshd_config"
    fi
  '';

  # Add script to start sshd
  environment.packages = [
    (pkgs.writeScriptBin "sshd-start" ''
      #!${pkgs.runtimeShell}
      ${pkgs.openssh}/bin/sshd -f "${sshdDirectory}/sshd_config" -D
    '')
  ];
}
