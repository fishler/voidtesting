#!/usr/bin/env bash
set -euo pipefail

# Void Linux interactive installer with explicit password and reboot prompts
# Run as root from live environment: sudo ./void-install.sh
xbps-install -Su -y xbps gptfdisk parted || y

prompt() {
  local varname="$1"; shift
  local prompt_text="$*"
  read -rp "$prompt_text: " "$varname"
  printf -v "$varname" "%s" "${!varname}"
}

confirm_yes() {
  local prompt_text="$1"
  read -rp "$prompt_text Type YES to continue: " CONFIRM
  [ "$CONFIRM" = "YES" ]
}

yn_prompt() {
  local prompt_text="$1"
  local default="${2:-n}"
  local ans
  read -rp "$prompt_text [$default]: " ans
  ans=${ans:-$default}
  case "${ans,,}" in
    y|yes) return 0;;
    *) return 1;;
  esac
}

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root: sudo $0"
  exit 1
fi

echo "Void Linux interactive installer"
echo "WARNING: This will partition and format the target disk. Back up any important data."
echo

# Collect user input
prompt TARGET_DISK "Target disk (example /dev/sda)"
TARGET_DISK=${TARGET_DISK:-/dev/sda}

prompt MY_USERNAME "Username to create"
MY_USERNAME=${MY_USERNAME:-user}

prompt FULL_NAME "Full name for the user"
FULL_NAME=${FULL_NAME:-$MY_USERNAME}

prompt PC_Name "PC name (hostname)"
PC_Name=${PC_Name:-Void}

read -rp "Keyboard layout (default us) [us]: " KEYMAP
KEYMAP=${KEYMAP:-us}

# Hibernation choice
while true; do
  read -rp "Enable hibernation (swap = 2 × RAM)? [y/N]: " HIB_CHOICE
  HIB_CHOICE=${HIB_CHOICE:-n}
  case "${HIB_CHOICE,,}" in
    y|yes) HIBERNATE=true; break;;
    n|no) HIBERNATE=false; break;;
    *) echo "Please answer y or n.";;
  esac
done

echo
echo "Target disk: $TARGET_DISK"
echo "User: $MY_USERNAME ($FULL_NAME)"
echo "Hostname: $PC_Name"
echo "Keyboard: $KEYMAP"
echo "Hibernation: $HIBERNATE"
echo

if ! confirm_yes "About to wipe $TARGET_DISK."; then
  echo "Aborted by user."
  exit 1
fi

# Set keyboard
if command -v loadkeys >/dev/null 2>&1; then
  loadkeys "$(ls /usr/share/kbd/keymaps/i386/**/*.map.gz | grep -m1 "$KEYMAP" || true)" || true
fi

# Configure xbps repositories
mkdir -p /etc/xbps.d
printf "repository=https://mirror.aarnet.edu.au/pub/voidlinux/current" | sudo tee /etc/xbps.d/00-repository-main.conf
printf "repository=https://mirror.aarnet.edu.au/pub/voidlinux/current/nonfree" | sudo tee /etc/xbps.d/10-repository-nonfree.conf
printf "repository=https://github.com/sofijacom/void-package/releases/latest/download/\n" | sudo tee /etc/xbps.d/sofijacom-void-repository.conf


# Ensure required tools are available in live environment
xbps-install -Su -y xbps gptfdisk parted btrfs-progs || true

# Partition disk: EFI 512MiB, Boot 1GiB, Root rest
sgdisk -o "$TARGET_DISK"
sgdisk -n 1:0:+512MiB -t 1:ef00 -c 1:"EFI" "$TARGET_DISK"
sgdisk -n 2:0:+1024MiB -t 2:8300 -c 2:"Boot" "$TARGET_DISK"
sgdisk -n 3:0:0 -t 3:8300 -c 3:"Root" "$TARGET_DISK"

# Filesystems
mkfs.vfat -F32 -n EFI "${TARGET_DISK}1"
mkfs.ext4 -L Boot "${TARGET_DISK}2"
mkfs.btrfs -f -L Root "${TARGET_DISK}3"

# BTRFS options and mount
BTRFS_OPTS="compress=zstd,noatime,space_cache=v2,discard=async,ssd"
mount -o "$BTRFS_OPTS" "${TARGET_DISK}3" /mnt

# Create subvolumes
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/var
btrfs subvolume create /mnt/var/cache
btrfs subvolume create /mnt/var/tmp
btrfs subvolume create /mnt/srv
btrfs subvolume create /mnt/var/swap
umount -l /mnt

# Mount subvolumes
mount -o "$BTRFS_OPTS,subvol=@" "${TARGET_DISK}3" /mnt
mkdir -p /mnt/home /mnt/.snapshots /mnt/var /mnt/efi /mnt/boot /mnt/srv /mnt/var/swap
mount -o "$BTRFS_OPTS,subvol=@home" "${TARGET_DISK}3" /mnt/home
mount -o "$BTRFS_OPTS,subvol=@snapshots" "${TARGET_DISK}3" /mnt/.snapshots
mount -o rw,noatime "${TARGET_DISK}1" /mnt/efi
mount -o rw,noatime "${TARGET_DISK}2" /mnt/boot

# Install base system into /mnt
REPO=https://mirror.aarnet.edu.au/pub/voidlinux/current
ARCH=x86_64
XBPS_ARCH=$ARCH xbps-install -S -r /mnt -R "$REPO" base-system bash zsh cryptsetup sudo nano git btrfs-progs base-devel efibootmgr mtools dosfstools grub-btrfs grub-x86_64-efi elogind dbus void-repo-nonfree || y

# Bind mounts for chroot
for dir in dev proc sys run; do
  mount --rbind "/$dir" "/mnt/$dir"
  mount --make-rslave "/mnt/$dir"
done

# Copy resolv for network inside chroot
cp /etc/resolv.conf /mnt/etc/

# Prepare chroot setup script without passwords
cat > /mnt/root/void_chroot_setup.sh <<'CHROOT_EOF'
#!/usr/bin/env bash
set -euo pipefail

BTRFS_OPTS_PLACEHOLDER="__BTRFS_OPTS__"
PC_NAME_PLACEHOLDER="__PC_NAME__"
DISK_BASENAME_PLACEHOLDER="__DISK_BASENAME__"
USER_PLACEHOLDER="__USER__"
FULLNAME_PLACEHOLDER="__FULLNAME__"
SWAP_GB_PLACEHOLDER="__SWAP_GB__"

# Set timezone and locale
ln -sf /usr/share/zoneinfo/Australia/Sydney /etc/localtime || true
sed -i 's/#KEYMAP="es"/KEYMAP="us"/g' /etc/rc.conf || true
sed -i 's/#HARDWARECLOCK="UTC"/HARDWARECLOCK="localtime"/g' /etc/rc.conf || true

echo -e "en_AU.UTF-8 UTF-8\nen_US.UTF-8 UTF-8" > /etc/default/libc-locales
xbps-reconfigure -f glibc-locales || true

# Hostname and hosts
echo "$PC_NAME_PLACEHOLDER" > /etc/hostname
sed -i "/# End of file/i 127.0.1.1\t$PC_NAME_PLACEHOLDER.local \t$PC_NAME_PLACEHOLDER" /etc/hosts || true

# Detect UUIDs for fstab
UEFI_UUID=$(blkid -s UUID -o value /dev/${DISK_BASENAME_PLACEHOLDER}1 || true)
GRUB_UUID=$(blkid -s UUID -o value /dev/${DISK_BASENAME_PLACEHOLDER}2 || true)
ROOT_UUID=$(blkid -s UUID -o value /dev/${DISK_BASENAME_PLACEHOLDER}3 || true)

cat > /etc/fstab <<FSTAB_EOF
UUID=$ROOT_UUID / btrfs $BTRFS_OPTS_PLACEHOLDER,subvol=@ 0 1
UUID=$UEFI_UUID /efi vfat defaults,noatime 0 2
UUID=$GRUB_UUID /boot ext4 defaults,noatime 0 2
UUID=$ROOT_UUID /home btrfs $BTRFS_OPTS_PLACEHOLDER,subvol=@home 0 2
UUID=$ROOT_UUID /.snapshots btrfs $BTRFS_OPTS_PLACEHOLDER,subvol=@snapshots 0 2
tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0
FSTAB_EOF

# Host only dracut setting
echo hostonly=yes >> /etc/dracut.conf || true

# Install microcode and grub packages
xbps-install -Su intel-ucode grub-x86_64-efi -y || true y

# Install and configure grub
grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id="Void Linux" || true y
grub-mkconfig -o /boot/grub/grub.cfg || true

# Create swapfile on BTRFS
mkdir -p /var/swap
chattr +C /var/swap || true
SWAP_GB=$SWAP_GB_PLACEHOLDER

if command -v btrfs >/dev/null 2>&1; then
  btrfs filesystem mkswapfile --size "${SWAP_GB}g" --uuid clear /var/swap/swapfile || true
fi

truncate -s 0 /var/swap/swapfile || true
dd if=/dev/zero of=/var/swap/swapfile bs=1G count="$SWAP_GB" status=progress || true
chmod 600 /var/swap/swapfile || true
mkswap /var/swap/swapfile || true
swapon /var/swap/swapfile || true

# Compute resume offset for swapfile and add to GRUB_CMDLINE_LINUX if possible
if command -v btrfs >/dev/null 2>&1 && command -v btrfs-inspect-internal >/dev/null 2>&1; then
  RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r /var/swap/swapfile 2>/dev/null || true)
else
  RESUME_OFFSET=""
fi

if [ -n "$RESUME_OFFSET" ]; then
  ROOT_UUID=$(blkid -s UUID -o value /dev/${DISK_BASENAME_PLACEHOLDER}3 || true)
  sed -i '/^GRUB_CMDLINE_LINUX=/d' /etc/default/grub || true
  echo "GRUB_CMDLINE_LINUX=\"resume=UUID=$ROOT_UUID resume_offset=$RESUME_OFFSET\"" >> /etc/default/grub
  grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id="Void Linux" || true
  grub-mkconfig -o /boot/grub/grub.cfg || true
fi

# Create user account without setting password
useradd -m -G wheel,input,video -s /bin/zsh -c "$FULLNAME_PLACEHOLDER" "$USER_PLACEHOLDER" || true

# Allow wheel group to sudo
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers || true

# Reconfigure packages
xbps-reconfigure -fa || true

echo "Chroot configuration complete. Please set passwords from the live environment using: chroot /mnt passwd and chroot /mnt passwd $USER_PLACEHOLDER"
CHROOT_EOF

# Replace placeholders in chroot script
DISK_BASENAME=$(basename "$TARGET_DISK")
# Determine RAM in GB rounded up
RAM_GB=$(awk '/MemTotal/ {printf("%.0f", ($2/1024/1024) + 0.5)}' /proc/meminfo)
if [ -z "$RAM_GB" ] || [ "$RAM_GB" -lt 1 ]; then
  RAM_GB=1
fi
if [ "$HIBERNATE" = true ]; then
  SWAP_GB=$((RAM_GB * 2))
else
  SWAP_GB=$RAM_GB
fi

sed -i "s|__BTRFS_OPTS__|$BTRFS_OPTS|g" /mnt/root/void_chroot_setup.sh
sed -i "s|__PC_NAME__|$PC_Name|g" /mnt/root/void_chroot_setup.sh
sed -i "s|__DISK_BASENAME__|$DISK_BASENAME|g" /mnt/root/void_chroot_setup.sh
sed -i "s|__USER__|$MY_USERNAME|g" /mnt/root/void_chroot_setup.sh
sed -i "s|__FULLNAME__|$FULL_NAME|g" /mnt/root/void_chroot_setup.sh
sed -i "s|__SWAP_GB__|$SWAP_GB|g" /mnt/root/void_chroot_setup.sh

chmod +x /mnt/root/void_chroot_setup.sh

# Run chroot script
chroot /mnt /bin/bash -c "/root/void_chroot_setup.sh"
touch /etc/xbps.d/00-repository-main.conf
touch /etc/xbps.d/10-repository-nonfree.conf
touch /etc/xbps.d/sofijacom-void-repository.conf
printf "repository=https://mirror.aarnet.edu.au/pub/voidlinux/current" | sudo tee /etc/xbps.d/00-repository-main.conf
printf "repository=https://mirror.aarnet.edu.au/pub/voidlinux/current/nonfree" | sudo tee /etc/xbps.d/10-repository-nonfree.conf
printf "repository=https://github.com/sofijacom/void-package/releases/latest/download/\n" | sudo tee /etc/xbps.d/sofijacom-void-repository.conf

sudo xbps-install -Su -y

# After chroot script completes, set passwords interactively inside chroot
echo
echo "You will now set passwords interactively inside the chroot."
echo

# Alert and set root password
echo "Setting password for account: root"
chroot /mnt passwd

# Alert and set user password
echo "Setting password for account: $MY_USERNAME"
chroot /mnt passwd "$MY_USERNAME"

# Offer to open an interactive chroot shell for additional manual configuration
if yn_prompt "Would you like to open an interactive chroot shell now? (use this to run extra commands manually) [y/N]"; then
  echo "Entering chroot. When finished, exit the shell to continue."
  chroot /mnt /bin/bash
fi

# Ask whether to reboot now
if yn_prompt "Reboot the system now? [y/N]"; then
  echo "Unmounting and rebooting..."
  umount -R -l /mnt || true
  reboot
else
  echo "Installation complete. The system was not rebooted."
  echo "To finish manually: unmount and reboot when ready:"
  echo "  umount -R -l /mnt"
  echo "  reboot"
fi

