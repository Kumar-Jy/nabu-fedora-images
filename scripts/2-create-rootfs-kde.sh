#!/bin/bash

# KDE Plasma variant: copies the base rootfs, installs the desktop,
# packs a minimized ext4 images/rootfs.img (label fedora_root) for the
# `linux` partition. Env: BUILD_VERSION

set -e

if [ -z "$1" ]; then
    echo "ERROR: base rootfs directory path not provided." >&2
    exit 1
fi

BASE_ROOTFS_DIR="$1"
VARIANT_NAME="kde"
ROOTFS_DIR="$PWD/fedora-rootfs-$VARIANT_NAME"
RELEASEVER="45"
ARCH="aarch64"
BUILD_VERSION="${BUILD_VERSION}"
ROOTFS_NAME="$PWD/rootfs.img"
IMG_SIZE="8G"

# --- 1. copy base rootfs
echo "Creating $VARIANT_NAME rootfs from base..."
rm -rf "$ROOTFS_DIR"
cp -a "$BASE_ROOTFS_DIR" "$ROOTFS_DIR"

mount_chroot_fs() {
    mkdir -p "$ROOTFS_DIR/proc" "$ROOTFS_DIR/sys" "$ROOTFS_DIR/dev" "$ROOTFS_DIR/dev/pts"
    mount --bind /proc "$ROOTFS_DIR/proc"
    mount --bind /sys "$ROOTFS_DIR/sys"
    mount --bind /dev "$ROOTFS_DIR/dev"
    mount --bind /dev/pts "$ROOTFS_DIR/dev/pts"
}
umount_chroot_fs() {
    umount "$ROOTFS_DIR/dev/pts" 2>/dev/null || true
    umount "$ROOTFS_DIR/dev" 2>/dev/null || true
    umount "$ROOTFS_DIR/sys" 2>/dev/null || true
    umount "$ROOTFS_DIR/proc" 2>/dev/null || true
}
trap umount_chroot_fs EXIT

mount_chroot_fs

# --- 2. install KDE Plasma inside chroot
echo "Installing KDE Plasma desktop inside chroot..."
chroot "$ROOTFS_DIR" /bin/bash <<'CHROOT_KDE'
set -e

echo 'Installing additional dependencies...'
dnf install -y \
    --nogpgcheck \
    --setopt=install_weak_deps=False \
    --setopt=skip_if_unavailable=True \
    alsa-utils \
    pipewire \
    wireplumber \
    upower

echo 'Installing KDE Plasma desktop...'
dnf install -y \
    --nogpgcheck \
    --setopt=install_weak_deps=False \
    --setopt=skip_if_unavailable=True \
    --exclude plasma-nm-l2tp \
    --exclude NetworkManager-l2tp \
    --exclude xl2tpd \
    --exclude glibc-all-langpacks \
    --exclude kdebugsettings \
    --exclude khelpcenter \
    --exclude akonadi-server \
    --exclude akonadi-server-mysql \
    --exclude plasma-print-manager \
    --exclude plasma-desktop-doc \
    --exclude google-droid-sans-fonts \
    --exclude google-noto-serif-fonts \
    --exclude qt5-qtwebkit \
    --exclude kwebkitpart \
    @kde-desktop \
    plasma-discover-packagekit \
    tar \
    fcitx5 \
    fcitx5-configtool \
    fcitx5-gtk \
    fcitx5-qt \
    fcitx5-chinese-addons

echo 'Configuring user + autologin...'
echo 'user:fedora' | chpasswd
echo '%wheel ALL=(ALL) ALL' > /etc/sudoers.d/99-wheel-user
chmod 0440 /etc/sudoers.d/99-wheel-user

mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/autologin.conf <<'EOF'
[Autologin]
User=user
Session=plasma
Relogin=false
EOF

echo 'Applying systemd presets...'
systemctl preset-all || true
systemctl set-default graphical.target

dnf clean all
CHROOT_KDE

umount_chroot_fs
trap - EXIT
sync

# --- 3. pack ext4 rootfs.img
echo "Creating ext4 rootfs image: $ROOTFS_NAME (initial size: $IMG_SIZE)"
fallocate -l "$IMG_SIZE" "$ROOTFS_NAME"
mkfs.ext4 -L fedora_root -F "$ROOTFS_NAME"

MOUNT_DIR=$(mktemp -d)
trap 'umount "$MOUNT_DIR" 2>/dev/null; rmdir -- "$MOUNT_DIR" 2>/dev/null' EXIT
mount -o loop "$ROOTFS_NAME" "$MOUNT_DIR"

echo "Copying rootfs contents to image..."
rsync -aHAXx "$ROOTFS_DIR/" "$MOUNT_DIR/"

echo "Unmounting image..."
umount "$MOUNT_DIR"
rmdir "$MOUNT_DIR"
trap - EXIT
sync

# --- 4. minimize the image
echo "Minimizing the image file..."
e2fsck -f -y "$ROOTFS_NAME" || true
resize2fs -M "$ROOTFS_NAME"
e2fsck -f -y "$ROOTFS_NAME" || true

MIN_BLOCKS=$(dumpe2fs -h "$ROOTFS_NAME" 2>/dev/null | grep 'Block count:' | awk '{print $3}')
BLOCK_SIZE_KB=$(dumpe2fs -h "$ROOTFS_NAME" 2>/dev/null | grep 'Block size:' | awk '{print $3 / 1024}')

if ! [[ "$MIN_BLOCKS" =~ ^[0-9]+$ ]] || ! [[ "$BLOCK_SIZE_KB" =~ ^[0-9]+$ ]]; then
    echo "ERROR: failed to read block info from image." >&2
    exit 1
fi

MIN_SIZE_KB=$((MIN_BLOCKS * BLOCK_SIZE_KB))
SAFETY_MARGIN_KB=204800
NEW_SIZE_KB=$((MIN_SIZE_KB + SAFETY_MARGIN_KB))

truncate -s "${NEW_SIZE_KB}K" "$ROOTFS_NAME"
resize2fs "$ROOTFS_NAME"

echo "======================================================================"
echo "KDE rootfs image created: $ROOTFS_NAME"
ls -la "$ROOTFS_NAME"
echo "======================================================================"
