#!/bin/bash

# ==============================================================================
# 2-create-rootfs-niri.sh
#
# Build the niri (wayland compositor) variant rootfs image on top of the base
# rootfs directory. Produces a minimized ext4 images/rootfs.img (label
# fedora_root) that is flashed to the `linux` partition by flash-linux.sh.
#
# niri is packaged in Fedora proper since Fedora 41 (no COPR needed on F45).
#
# Env:
#   BUILD_VERSION   e.g. 45
# ==============================================================================

set -e

if [ -z "$1" ]; then
    echo "ERROR: base rootfs directory path not provided." >&2
    exit 1
fi

BASE_ROOTFS_DIR="$1"
VARIANT_NAME="niri"
ROOTFS_DIR="$PWD/fedora-rootfs-$VARIANT_NAME"
RELEASEVER="45"
ARCH="aarch64"
BUILD_VERSION="${BUILD_VERSION}"
ROOTFS_NAME="$PWD/rootfs.img"
IMG_SIZE="8G"

# --- 1. copy base rootfs -------------------------------------------------------
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

# --- 2. install niri inside chroot -----------------------------------------------
echo "Installing niri desktop inside chroot..."
chroot "$ROOTFS_DIR" /bin/bash <<'CHROOT_NIRI'
set -e

echo 'Installing base graph + niri...'
dnf install -y \
    --nogpgcheck \
    --setopt=install_weak_deps=False \
    --setopt=skip_if_unavailable=True \
    @standard \
    @base-graphical \
    niri \
    foot \
    xdg-desktop-portal-gnome \
    nautilus \
    gnome-console \
    fcitx5 \
    fcitx5-configtool \
    fcitx5-gtk \
    fcitx5-qt \
    fcitx5-chinese-addons

echo 'Installing sddm for niri session...'
dnf install -y \
    --nogpgcheck \
    --setopt=install_weak_deps=False \
    --setopt=skip_if_unavailable=True \
    sddm \
    sddm-wayland-generic \
    niri-session || true

echo 'Configuring user + autologin...'
echo 'user:fedora' | chpasswd
echo '%wheel ALL=(ALL) ALL' > /etc/sudoers.d/99-wheel-user
chmod 0440 /etc/sudoers.d/99-wheel-user

mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/autologin.conf <<'EOF'
[Autologin]
User=user
Session=niri
Relogin=false
EOF

systemctl set-default graphical.target
systemctl enable sddm 2>/dev/null || true

dnf clean all
CHROOT_NIRI

umount_chroot_fs
trap - EXIT
sync

# --- 3. pack ext4 rootfs.img ----------------------------------------------------
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

# --- 4. minimize the image -------------------------------------------------------
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
echo "niri rootfs image created: $ROOTFS_NAME"
ls -la "$ROOTFS_NAME"
echo "======================================================================"