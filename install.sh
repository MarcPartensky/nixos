# (Optionnel mais recommandé) Garder un tmpfs large au cas où
mount -o remount,size=8G /tmp
mount -o remount,size=8G /run/nixos

# 2. Lancer un shell avec disko et git
nix-shell -p disko git

# --- Dans le nix-shell ---

# 3. Partitionner
disko --flake .#tower --mode disko

# 4. Générer la config hardware (et vérifier les changements si besoin)
nixos-generate-config --root /mnt --show-hardware-config

# 5. Installer NixOS en augmentant le buffer de téléchargement à 1 Go
nixos-install --flake .#tower --root /mnt --no-root-passwd --option download-buffer-size 1073741824

# 6. Quitter et redémarrer
exit
reboot
