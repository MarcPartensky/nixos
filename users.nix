{ pkgs, ... }:
{
  users.users = {
      root = {
        isNormalUser = false;
        shell = pkgs.zsh;
        initialHashedPassword = "$6$m6HmpBg7jzxJZhwX$OcKxHxT4tyhwSh9decgeAVmiC1J6QphiWWaVJv6cMfONUeWS8ap1No/pnkINqD2h0GGO/ptNtVWjZwQOe7KXd1";
        openssh.authorizedKeys.keys = [ "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDiUE73uIEgijfmSsDwBvZmecQnqjBUPRKlMDmevsThc1YJNWEHl57NNIUcx6XSCDPKu5azayImLqIBt8wT5xlqtNX20uCnikDfXZ8gFbGlMRTGZKutQZIRmUrUS5mz97S4dVVK+n5WU+OwOfEg/XKXPh4WbTVDpfTTg7RopRAXkma56HV2TJM0ndPRN8VLmBmtnwdQwEpJ0tRRY+KOHmTojsH65eaZ89+BHbto+Kg+lk6x8IH5VDCRQNHgTEccOpOGYBSHRpoZi1a5h3yajf/eGAQ9Cd38DOsfMtm84oFlii7oXPyxwXoM+uH1SDnvLXyheIrV/XLUurSbEb4aJni6Zu79Z9l8xHhUNmVNSZqWOWUvPbAHlDKUzsbxgk9Zs9OTvSDaRzGhViYl4e1Qc993yerGSW1HHIvYUKM7o5nSQqskSOvOI+ahL5fIbgdyVx4FeuURZIyZSxCz4jIJTK15/6pkT/miHKv+vmQhsoLCqgyXY4SG1p9ruzKkzBe03ZQVW5WeFDLYRjZ+Z4Q2IL2K3BmLgp8tInkPJizQ7v5UGSiajJmPxY0j+CqdH9ZlIBdf8GS+run/N4hpMC1/ayUZRbCY5jg4c8bev8dKEZYJKPs/Hq2zLRZe4YtxcKuiGhgIwQOzo/QrCvSM4pVDgo+d2DjEzIdapqE8hF6BHWDg/w== marc.partensky@gmail.com" ];
      };
      marc = {
        isNormalUser = true;
        home = "/home/marc";
        description = "Marc Partensky";
        extraGroups = ["wheel" "networkmanager" "docker" "seat" "kvm" "video"];
        # openssh.authorizedKeys.keys =
        shell = pkgs.zsh;
        # initialHashedPassword = "$6$0QAYnBqAJtqB12p3$2lb7rAS2sYw49GUJt0L0bAEpZJSv4HZARQjlbYPhexSmeRB71IRMBzXjf3b4rX6fuDxOuDLydP/Kni9uraS5j/";
        initialHashedPassword = "$6$m6HmpBg7jzxJZhwX$OcKxHxT4tyhwSh9decgeAVmiC1J6QphiWWaVJv6cMfONUeWS8ap1No/pnkINqD2h0GGO/ptNtVWjZwQOe7KXd1";
        openssh.authorizedKeys.keys = [ "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDiUE73uIEgijfmSsDwBvZmecQnqjBUPRKlMDmevsThc1YJNWEHl57NNIUcx6XSCDPKu5azayImLqIBt8wT5xlqtNX20uCnikDfXZ8gFbGlMRTGZKutQZIRmUrUS5mz97S4dVVK+n5WU+OwOfEg/XKXPh4WbTVDpfTTg7RopRAXkma56HV2TJM0ndPRN8VLmBmtnwdQwEpJ0tRRY+KOHmTojsH65eaZ89+BHbto+Kg+lk6x8IH5VDCRQNHgTEccOpOGYBSHRpoZi1a5h3yajf/eGAQ9Cd38DOsfMtm84oFlii7oXPyxwXoM+uH1SDnvLXyheIrV/XLUurSbEb4aJni6Zu79Z9l8xHhUNmVNSZqWOWUvPbAHlDKUzsbxgk9Zs9OTvSDaRzGhViYl4e1Qc993yerGSW1HHIvYUKM7o5nSQqskSOvOI+ahL5fIbgdyVx4FeuURZIyZSxCz4jIJTK15/6pkT/miHKv+vmQhsoLCqgyXY4SG1p9ruzKkzBe03ZQVW5WeFDLYRjZ+Z4Q2IL2K3BmLgp8tInkPJizQ7v5UGSiajJmPxY0j+CqdH9ZlIBdf8GS+run/N4hpMC1/ayUZRbCY5jg4c8bev8dKEZYJKPs/Hq2zLRZe4YtxcKuiGhgIwQOzo/QrCvSM4pVDgo+d2DjEzIdapqE8hF6BHWDg/w== marc.partensky@gmail.com" ];
      };
    };
}
