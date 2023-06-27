#!/bin/env sh

lsblk
echo ""

read -p "disk: " DISK
read -p "swapsize GiB: " SWAPSIZEGIB
read -p "reserve GiB: " RESERVEGIB
read -sp "password: " POOLPASS

EMAIL="marc@marcpartensky.com"
NAME="Marc Partensky"

RESERVE=$((RESERVEGIB * 1024))
SWAPSIZE=$((SWAPSIZEGIB * 1024))


MNT=$(mktemp -d)

log() { echo -e "\n\033[1m${@}\033[0m"; }

log Destroying zfs pool rpool and bpool just in case
zpool destroy bpool
zpool destroy rpool

log Unmounting filesystems just in case
# ---
umount -Rl "${MNT}"
zpool export -a

log Enabling Nix Flakes functionality
# ---
# mkdir -p ~/.config/nix
# echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf


log Installing programs needed for system installation
# ---
if ! command -v git; then nix-env -f '<nixpkgs>' -iA git; fi
if ! command -v jq;  then nix-env -f '<nixpkgs>' -iA jq; fi
if ! command -v partprobe;  then nix-env -f '<nixpkgs>' -iA parted; fi


log Partition the disks
# ---
partition_disk () {
 local disk="${1}"
 blkdiscard -f "${disk}" || true

 parted --script --align=optimal  "${disk}" -- \
     mklabel gpt \
     mkpart swap  1MiB $((SWAPSIZE + 1))MiB \
     mkpart rpool $((SWAPSIZE + 1))MiB -$((RESERVE + 100))MiB \
     mkpart bpool -$((RESERVE + 100))MiB -$((RESERVE + 3))MiB \
     mkpart EFI -$((RESERVE + 3))MiB -$((RESERVE + 2))MiB \
     mkpart BIOS -$((RESERVE + 2))MiB -$((RESERVE + 1))MiB \
     set 4 esp on \
     set 5 bios_grub on \
     set 5 legacy_boot on

 partprobe "${disk}"
 udevadm settle
}

for i in ${DISK}; do
   partition_disk "${i}"
done


log Creating boot pool
# ---
# shellcheck disable=SC2046
zpool create \
    -o compatibility=grub2 \
    -o ashift=12 \
    -o autotrim=on \
    -O acltype=posixacl \
    -O canmount=off \
    -O compression=lz4 \
    -O devices=off \
    -O normalization=formD \
    -O relatime=on \
    -O xattr=sa \
    -O mountpoint=/boot \
    -R "${MNT}" \
    bpool \
    $(for i in ${DISK}; do
       printf '%s ' "${i}3";
      done)


log Creating root pool
# ---
# shellcheck disable=SC2046
echo $POOLPASS | zpool create \
    -o ashift=12 \
    -o autotrim=on \
    -R "${MNT}" \
    -O acltype=posixacl \
    -O canmount=off \
    -O compression=zstd \
    -O dnodesize=auto \
    -O normalization=formD \
    -O relatime=on \
    -O xattr=sa \
    -O mountpoint=/ \
    -o feature@encryption=enabled \
    -O encryption=on \
    -O keyformat=passphrase \
    rpool \
   $(for i in ${DISK}; do
      printf '%s ' "${i}2";
     done)


log Creating encrypted root system container
# ---
echo $POOLPASS | zfs create \
    -o canmount=off \
    -o mountpoint=none \
    -o encryption=on \
    -o keylocation=prompt \
    -o keyformat=passphrase \
    rpool/nixos


log Creating system datasets, managing mountpoints with mountpoint=legacy
# ---
zfs create -o mountpoint=legacy     rpool/nixos/root
mount -t zfs rpool/nixos/root "${MNT}"/
zfs create -o mountpoint=legacy rpool/nixos/home
mkdir "${MNT}"/home
mount -t zfs rpool/nixos/home "${MNT}"/home
zfs create -o mountpoint=legacy  rpool/nixos/var
zfs create -o mountpoint=legacy rpool/nixos/var/lib
zfs create -o mountpoint=legacy rpool/nixos/var/log
zfs create -o mountpoint=none bpool/nixos
zfs create -o mountpoint=legacy bpool/nixos/root
mkdir "${MNT}"/boot
mount -t zfs bpool/nixos/root "${MNT}"/boot
mkdir -p "${MNT}"/var/log
mkdir -p "${MNT}"/var/lib
mount -t zfs rpool/nixos/var/lib "${MNT}"/var/lib
mount -t zfs rpool/nixos/var/log "${MNT}"/var/log
zfs create -o mountpoint=legacy rpool/nixos/empty
zfs snapshot rpool/nixos/empty@start


log Formatting and mounting ESP
# ---
for i in ${DISK}; do
 mkfs.vfat -n EFI "${i}"1
 mkdir -p "${MNT}"/boot/efis/"${i##*/}"1
 mount -t vfat -o iocharset=iso8859-1 "${i}"1 "${MNT}"/boot/efis/"${i##*/}"1
done


log Cloning template flake configuration
# ---
mkdir -p "${MNT}"/etc
git clone --depth 1 --branch custom \
  https://github.com/marcpartensky/dotfiles-flake.git "${MNT}"/etc/nixos

rm -rf "${MNT}"/etc/nixos/.git
git -C "${MNT}"/etc/nixos/ init -b master
git -C "${MNT}"/etc/nixos/ add "${MNT}"/etc/nixos/
git -C "${MNT}"/etc/nixos config user.email $EMAIL
git -C "${MNT}"/etc/nixos config user.name $NAME
git -C "${MNT}"/etc/nixos commit -asm 'initial commit'


log Customizing configuration to your hardware
# ---
for i in ${DISK}; do
  sed -i \
  "s|/dev/disk/by-id/|${i%/*}/|" \
  "${MNT}"/etc/nixos/hosts/nixos/default.nix
  break
done

diskNames=""
for i in ${DISK}; do
  diskNames="${diskNames} \"${i##*/}\""
done

sed -i "s|\"bootDevices_placeholder\"|${diskNames}|g" \
  "${MNT}"/etc/nixos/hosts/nixos/default.nix

sed -i "s|\"abcd1234\"|\"$(head -c4 /dev/urandom | od -A none -t x4| sed 's| ||g' || true)\"|g" \
  "${MNT}"/etc/nixos/hosts/nixos/default.nix

sed -i "s|\"x86_64-linux\"|\"$(uname -m || true)-linux\"|g" \
  "${MNT}"/etc/nixos/flake.nix

cp "$(command -v nixos-generate-config || true)" ./nixos-generate-config

chmod a+rw ./nixos-generate-config

# shellcheck disable=SC2016
echo 'print STDOUT $initrdAvailableKernelModules' >> ./nixos-generate-config

kernelModules="$(./nixos-generate-config --show-hardware-config --no-filesystems | tail -n1 || true)"

sed -i "s|\"kernelModules_placeholder\"|${kernelModules}|g" \
  "${MNT}"/etc/nixos/hosts/nixos/default.nix

log Setting root password
# ---
rootPwd=$(mkpasswd -m SHA-512)
sed -i \
"s|rootHash_placeholder|${rootPwd}|" \
"${MNT}"/etc/nixos/configuration.nix


log Commiting changes to local repo
# ---
git -C "${MNT}"/etc/nixos commit -asm 'initial installation'

log Updating flake lock file to track latest system version
# ---
nix flake update --commit-lock-file \
  "git+file://${MNT}/etc/nixos"

log Installing system and apply configuration
# ---
nixos-install \
--root "${MNT}" \
--no-root-passwd \
--flake "git+file://${MNT}/etc/nixos#nixos"


log Setuping encrypted swap. This is useful if the available memory is small
# ---
for i in ${DISK}; do
   cryptsetup open --type plain --key-file /dev/random "${i}"1 "${i##*/}"1
   mkswap /dev/mapper/"${i##*/}"1
   swapon /dev/mapper/"${i##*/}"1
done

log Unmounting filesystems
# ---
umount -Rl "${MNT}"
zpool export -a


log The installation is done, enjoy
