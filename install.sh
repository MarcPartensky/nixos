# 0. Passer en root dès le départ
sudo -i

# Augmenter le buffer (tmpfs en RAM) pour éviter les erreurs "No space left on device"
# lors de l'évaluation du flake. Ajuste "8G" selon la RAM de ta machine.
mount -o remount,size=8G /tmp
mount -o remount,size=8G /run/nixos

# 1. Cloner ta configuration et s'y placer
git clone https://github.com/marcpartensky/nixos
cd nixos

# 2. Lancer un shell éphémère contenant disko (et git, souvent nécessaire pour évaluer les flakes)
nix-shell -p disko git

# --- À partir d'ici, tu es dans le nix-shell (toujours en root) ---

# 3. Partitionner (plus besoin de sudo vu qu'on est déjà root)
disko --flake .#tower --mode disko

# 4. Générer le hardware-configuration
nixos-generate-config --root /mnt --show-hardware-config

# (C'est le moment de comparer l'output avec ton hosts/tower/hardware-configuration.nix
# et de faire les modifications si besoin dans un autre terminal ou avec nano/vim)

# 5. Installer NixOS
nixos-install --flake .#tower --root /mnt --no-root-passwd

# 6. Sortir du nix-shell et redémarrer
exit
reboot
