# (Optional but recommended) Keep a large tmpfs just in case
mount -o remount,size=8G /tmp
mount -o remount,size=8G /run/nixos

# 2. Start a shell with disko and git
# nix-shell -p disko git

# --- Inside the nix-shell ---

# 3. Partition
disko --flake .#tower --mode disko

# 4. Generate the hardware config (and review the changes if needed)
nixos-generate-config --root /mnt --show-hardware-config

# 5. Install NixOS with the download buffer increased to 1 GB
nixos-install --flake .#tower --root /mnt --no-root-passwd --option download-buffer-size 1073741824

# 6. Exit and reboot
exit
reboot
