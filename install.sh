#!/usr/bin/env -S bash -e

# Options
microcode=intel-ucode # opts: 1) amd-ucode 2) intel-ucode
kernel=linux # opts: 1) linux 2) linux-hardened 3) linux-lts 4) linux-zen
network=networkmanager # opts: 1) iwd 2) networkmanager 3) wpa_supplicant
hostname="neptuno"
locale="en_US.UTF-8" 
kblayout=us

# Paths
disk="/dev/nvme0n1" # lsblk -dpnoNAME|grep -P "/dev/sd|nvme|vd"
esp="/dev/disk/by-partlabel/ESP"
cryptroot="/dev/disk/by-partlabel/Cryptroot"
btrfs="/dev/mapper/cryptroot"

# Cleaning the TTY.
clear

echo "Installing NetworkManager."
pacstrap /mnt $network
systemctl enable NetworkManager --root=/mnt &>/dev/null 

# Deleting old partition scheme.
echo "Delete the current partition table on $disk."
wipefs -af "$disk" &>/dev/null
sgdisk -Zo "$disk" &>/dev/null

# Creating a new partition scheme.
echo "Creating new partition scheme on $disk."
parted -s "$disk" \
    mklabel gpt \
    mkpart ESP fat32 1MiB 513MiB \
    set 1 esp on \
    mkpart Cryptroot 513MiB 100% \

# Informing the Kernel of the changes.
echo "Informing the Kernel about the disk changes."
partprobe "$disk"

# Formatting the ESP as FAT32.
echo "Formatting the EFI Partition as FAT32."
mkfs.fat -F 32 $esp &>/dev/null

# Creating a LUKS Container for the root partition.
echo "Creating LUKS Container for the root partition"
cryptsetup luksFormat $cryptroot
echo "Opening the newly created LUKS Container."
cryptsetup open $cryptroot cryptroot

# Formatting the LUKS Container as BTRFS.
echo "Formatting the LUKS container as BTRFS."
mkfs.btrfs $btrfs &>/dev/null
mount $btrfs /mnt

# Creating BTRFS subvolumes.
echo "Creating BTRFS subvolumes."
btrfs su cr /mnt/@ &>/dev/null
btrfs su cr /mnt/@home &>/dev/null
btrfs su cr /mnt/@snapshots &>/dev/null
btrfs su cr /mnt/@var_log &>/dev/null

# Mounting the newly created subvolumes.
umount /mnt
echo "Mounting the newly created subvolumes."
mount -o ssd,noatime,space_cache,compress=zstd,subvol=@ $btrfs /mnt
mkdir -p /mnt/{home,.snapshots,/var/log,boot}
mount -o ssd,noatime,space_cache,compress=zstd,autodefrag,discard=async,subvol=@home $btrfs /mnt/home
mount -o ssd,noatime,space_cache,compress=zstd,autodefrag,discard=async,subvol=@snapshots $btrfs /mnt/.snapshots
mount -o ssd,noatime,space_cache,compress=zstd,autodefrag,discard=async,subvol=@var_log $btrfs /mnt/var/log
chattr +C /mnt/var/log
mount $esp /mnt/boot/

kernel_selector

# Pacstrap (setting up a base sytem onto the new root).
echo "Installing the base system (it may take a while)."
pacstrap /mnt base $kernel $microcode linux-firmware btrfs-progs grub grub-btrfs efibootmgr snapper reflector base-devel snap-pac zram-generator

network_selector

# Generating /etc/fstab.
echo "Generating a new fstab."
genfstab -U /mnt >> /mnt/etc/fstab

# Setting hostname.
echo $hostname > /mnt/etc/hostname

# Setting up locales.
echo "$locale UTF-8"  > /mnt/etc/locale.gen
echo "LANG=$locale" > /mnt/etc/locale.conf

# Setting up keyboard layout.
echo "KEYMAP=$kblayout" > /mnt/etc/vconsole.conf

# Setting hosts file.
echo "Setting hosts file."
cat > /mnt/etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $hostname.localdomain   $hostname
EOF

# Configuring /etc/mkinitcpio.conf.
echo "Configuring /etc/mkinitcpio.conf for LUKS hook."
sed -i -e 's,modconf block filesystems keyboard,keyboard keymap modconf block encrypt filesystems,g' /mnt/etc/mkinitcpio.conf

# Setting up LUKS2 encryption and apparmor.
UUID=$(blkid $cryptroot | cut -f2 -d'"')
sed -i "s/quiet/quiet cryptdevice=UUID=$UUID:cryptroot root=$BTRFS/g" /mnt/etc/default/grub

# Configuring the system.    
arch-chroot /mnt /bin/bash -e <<EOF
    
    # Setting up timezone.
    ln -sf /usr/share/zoneinfo/$(curl -s http://ip-api.com/line?fields=timezone) /etc/localtime &>/dev/null
    
    # Setting up clock.
    hwclock --systohc

    # Generating locales.
    echo "Generating locales."
    locale-gen &>/dev/null

    # Generating a new initramfs.
    echo "Creating a new initramfs."
    mkinitcpio -P &>/dev/null

    # Snapper configuration
    umount /.snapshots
    rm -r /.snapshots
    snapper --no-dbus -c root create-config /
    btrfs subvolume delete /.snapshots &>/dev/null
    mkdir /.snapshots
    mount -a
    chmod 750 /.snapshots

    # Installing GRUB.
    echo "Installing GRUB on /boot."
    grub-install --target=x86_64-efi --efi-directory=/boot/ --bootloader-id=GRUB &>/dev/null
    
    # Creating grub config file.
    echo "Creating GRUB config file."
    grub-mkconfig -o /boot/grub/grub.cfg &>/dev/null
EOF

# Setting root password.
echo "Setting root password."
arch-chroot /mnt /bin/passwd

# Enabling Reflector timer.
echo "Enabling Reflector."
systemctl enable reflector.timer --root=/mnt &>/dev/null

# Enabling Snapper automatic snapshots.
echo "Enabling Snapper and automatic snapshots entries."
systemctl enable snapper-timeline.timer --root=/mnt &>/dev/null
systemctl enable snapper-cleanup.timer --root=/mnt &>/dev/null
systemctl enable grub-btrfs.path --root=/mnt &>/dev/null

# Enabling systemd-oomd.
echo "Enabling systemd-oomd."
systemctl enable systemd-oomd --root=/mnt &>/dev/null

# ZRAM configuration
bash -c 'cat > /mnt/etc/systemd/zram-generator.conf' <<-'EOF'
[zram0]
zram-fraction = 1
max-zram-size = 8192
EOF

# Finishing up
echo "Done, you may now wish to reboot (further changes can be done by chrooting into /mnt)."
exit
