{ pkgs, lib, ... }:
{
  users.users = {
      root = {
        isNormalUser = false;
        shell = pkgs.zsh;
        initialHashedPassword = lib.mkDefault "$6$m6HmpBg7jzxJZhwX$OcKxHxT4tyhwSh9decgeAVmiC1J6QphiWWaVJv6cMfONUeWS8ap1No/pnkINqD2h0GGO/ptNtVWjZwQOe7KXd1";
        openssh.authorizedKeys.keys = [ "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDiUE73uIEgijfmSsDwBvZmecQnqjBUPRKlMDmevsThc1YJNWEHl57NNIUcx6XSCDPKu5azayImLqIBt8wT5xlqtNX20uCnikDfXZ8gFbGlMRTGZKutQZIRmUrUS5mz97S4dVVK+n5WU+OwOfEg/XKXPh4WbTVDpfTTg7RopRAXkma56HV2TJM0ndPRN8VLmBmtnwdQwEpJ0tRRY+KOHmTojsH65eaZ89+BHbto+Kg+lk6x8IH5VDCRQNHgTEccOpOGYBSHRpoZi1a5h3yajf/eGAQ9Cd38DOsfMtm84oFlii7oXPyxwXoM+uH1SDnvLXyheIrV/XLUurSbEb4aJni6Zu79Z9l8xHhUNmVNSZqWOWUvPbAHlDKUzsbxgk9Zs9OTvSDaRzGhViYl4e1Qc993yerGSW1HHIvYUKM7o5nSQqskSOvOI+ahL5fIbgdyVx4FeuURZIyZSxCz4jIJTK15/6pkT/miHKv+vmQhsoLCqgyXY4SG1p9ruzKkzBe03ZQVW5WeFDLYRjZ+Z4Q2IL2K3BmLgp8tInkPJizQ7v5UGSiajJmPxY0j+CqdH9ZlIBdf8GS+run/N4hpMC1/ayUZRbCY5jg4c8bev8dKEZYJKPs/Hq2zLRZe4YtxcKuiGhgIwQOzo/QrCvSM4pVDgo+d2DjEzIdapqE8hF6BHWDg/w== marc.partensky@gmail.com" ];
      };
      marc = {
        isNormalUser = true;
        home = "/home/marc";
        # the home already exists: prevents update-users-groups.pl from redoing
        # a chown/chmod 700 on each activation (broke hermes' ACL mask)
        createHome = false;
        description = "Marc Partensky";
        extraGroups = [
          "wheel"
          "networkmanager"
          "docker"
          "seat"
          "kvm"
          "video"
          "lp"
          "input"
          "network"
          "manager"
          "ydotool"
          # hermes sessions launched by marc in the herdr panes: they
          # share the service's state dir /var/lib/hermes/.hermes (cf
          # HERMES_HOME in users/marc/home.nix), hence group hermes access.
          "hermes"
        ];
        # openssh.authorizedKeys.keys =
        shell = pkgs.zsh;
        # initialHashedPassword = "$6$0QAYnBqAJtqB12p3$2lb7rAS2sYw49GUJt0L0bAEpZJSv4HZARQjlbYPhexSmeRB71IRMBzXjf3b4rX6fuDxOuDLydP/Kni9uraS5j/";
        # ancien : initialHashedPassword = "$6$m6HmpBg7jzxJZhwX$OcKxHxT4tyhwSh9decgeAVmiC1J6QphiWWaVJv6cMfONUeWS8ap1No/pnkINqD2h0GGO/ptNtVWjZwQOe7KXd1";
        # reset 25/09/2026: hashedPassword (not initial) to force the value on switch, marc could no longer log in.
        hashedPassword = "$6$dE28cUDZ9G81wzwo$JoO.6M91zdtR0ja/g1pw/LKE8aAMugmGkIyOiSuqdjEWVKId9F2jxqdvh5Bo69uOC3/g7uP6O3mZmzxqD2pKU1";
        # RSA key: legacy clients. ed25519 = marc@Air-de-Marc, the key his Mac
        # uses, so `ssh laptop` / `ssh tower` work with the same identity from
        # any tailnet device (tower and deck already append it explicitly).
        openssh.authorizedKeys.keys = [
          "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDiUE73uIEgijfmSsDwBvZmecQnqjBUPRKlMDmevsThc1YJNWEHl57NNIUcx6XSCDPKu5azayImLqIBt8wT5xlqtNX20uCnikDfXZ8gFbGlMRTGZKutQZIRmUrUS5mz97S4dVVK+n5WU+OwOfEg/XKXPh4WbTVDpfTTg7RopRAXkma56HV2TJM0ndPRN8VLmBmtnwdQwEpJ0tRRY+KOHmTojsH65eaZ89+BHbto+Kg+lk6x8IH5VDCRQNHgTEccOpOGYBSHRpoZi1a5h3yajf/eGAQ9Cd38DOsfMtm84oFlii7oXPyxwXoM+uH1SDnvLXyheIrV/XLUurSbEb4aJni6Zu79Z9l8xHhUNmVNSZqWOWUvPbAHlDKUzsbxgk9Zs9OTvSDaRzGhViYl4e1Qc993yerGSW1HHIvYUKM7o5nSQqskSOvOI+ahL5fIbgdyVx4FeuURZIyZSxCz4jIJTK15/6pkT/miHKv+vmQhsoLCqgyXY4SG1p9ruzKkzBe03ZQVW5WeFDLYRjZ+Z4Q2IL2K3BmLgp8tInkPJizQ7v5UGSiajJmPxY0j+CqdH9ZlIBdf8GS+run/N4hpMC1/ayUZRbCY5jg4c8bev8dKEZYJKPs/Hq2zLRZe4YtxcKuiGhgIwQOzo/QrCvSM4pVDgo+d2DjEzIdapqE8hF6BHWDg/w== marc.partensky@gmail.com"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMdX5m7b8xWL/9ZUeFRxahB4YY0v2rAV5CCFv8xTOlUh marc@Air-de-Marc"
        ];
      };
    };
}
