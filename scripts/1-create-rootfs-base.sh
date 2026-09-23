#!/bin/bash

# ==============================================================================
# 1-create-rootfs-base.sh
#
# Build a Fedora 45 aarch64 base rootfs directory for nabu (Xiaomi Pad 5),
# install the linux-nabu kernel (extracted from the nightly ZIP or nabu-pkgs
# release), generate a UKI with dracut + systemd-ukify, embed the rEFInd
# dualboot bootmanager, and produce:
#   - fedora-rootfs-base/   (rootfs directory, consumed by variant scripts)
#   - efi-files.zip         (EFI directory contents)
#   - flashable_esp.img.zst (flashable ESP image)
#
# Kernel sources (priority order):
#   1. $NIGHTLY_KERNEL_URL - ZIP containing linux-nabu-*.pkg.tar.* (nightly.link)
#   2. default             - linux-nabu-<KERNEL_VERSION>-aarch64.pkg.tar.xz
#                            from the nabu-pkgs GitHub release
#
# Env:
#   BUILD_VERSION       e.g. 45
#   KERNEL_VERSION      e.g. 6.14.11-8 (default)
#   NIGHTLY_KERNEL_URL  optional ZIP URL for kernel packages
# ==============================================================================

set -e

ROOTFS_DIR="$PWD/fedora-rootfs-base"
RELEASEVER="45"
ARCH="aarch64"
BUILD_VERSION="${BUILD_VERSION}"
KERNEL_VERSION="${KERNEL_VERSION:-6.14.11-8}"
NIGHTLY_KERNEL_URL="${NIGHTLY_KERNEL_URL:-}"
REPO_OWNER="${GITHUB_REPOSITORY_OWNER:-Kumar-Jy}"

# --- helpers ----------------------------------------------------------------
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

# unpack an Arch .pkg.tar.xz/.zst into the rootfs, stripping pkg metadata
unpack_arch_pkg() {
    local pkg="$1"
    echo ">>> Unpacking $pkg into rootfs"
    case "$pkg" in
        *.tar.zst|*.pkg.tar.zst) tar --zstd -xf "$pkg" -C "$ROOTFS_DIR" ;;
        *)                       tar -xJf "$pkg" -C "$ROOTFS_DIR" ;;
    esac
    rm -f "$ROOTFS_DIR"/.BUILDINFO "$ROOTFS_DIR"/.MTREE "$ROOTFS_DIR"/.PKGINFO "$ROOTFS_DIR"/.INSTALL
}

echo "======================================================================"
echo "Building Fedora $RELEASEVER ($ARCH) base rootfs for nabu"
echo "KERNEL_VERSION=$KERNEL_VERSION NIGHTLY_KERNEL_URL=$NIGHTLY_KERNEL_URL"
echo "======================================================================"

rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"
mount_chroot_fs

# temp resolv.conf for the chroot bootstrap
rm -f "$ROOTFS_DIR/etc/resolv.conf"
mkdir -p "$ROOTFS_DIR/etc"
cat > "$ROOTFS_DIR/etc/resolv.conf" <<'EOF'
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
nameserver 1.0.0.1
EOF

# --- bootstrap base system --------------------------------------------------
echo ">>> Bootstrapping Fedora $RELEASEVER $ARCH"
TEMP_REPO_DIR=$(mktemp -d)
cat > "${TEMP_REPO_DIR}/temp-fedora.repo" <<EOF
[temp-fedora]
name=Temporary Fedora $RELEASEVER - $ARCH
metalink=https://mirrors.fedoraproject.org/metalink?repo=fedora-$RELEASEVER&arch=$ARCH
enabled=1
gpgcheck=0
skip_if_unavailable=False
EOF

dnf install -y --installroot="$ROOTFS_DIR" --forcearch="$ARCH" \
    --releasever="$RELEASEVER" \
    --setopt=install_weak_deps=False \
    --setopt="reposdir=${TEMP_REPO_DIR}" \
    --nogpgcheck \
    fedora-repos \
    fedora-release \
    bash \
    dnf
rm -rf -- "$TEMP_REPO_DIR"

# --- main installation inside chroot -----------------------------------------
echo ">>> Configuring system inside chroot"
cat > "$ROOTFS_DIR/root/setup.sh" <<'CHROOT_SETUP'
set -e
set -o pipefail

# On F45 beta the updates repo can be 404; keep going regardless
dnf config-manager setopt fedora.skip_if_unavailable=True 2>/dev/null || true

echo 'Installing core packages...'
dnf install -y --nogpgcheck \
    --releasever=45 \
    --setopt=install_weak_deps=False \
    --setopt=skip_if_unavailable=True \
    --allowerasing \
    @core

echo 'Installing hardware support + nabu services...'
dnf install -y --nogpgcheck \
    --releasever=45 \
    --setopt=install_weak_deps=False \
    --setopt=skip_if_unavailable=True \
    --exclude dracut-config-rescue \
    --exclude 'amd-gpu-firmware,brcmfmac-firmware,intel-gpu-firmware,iwlegacy-firmware,iwlwifi-dvm-firmware,iwlwifi-mvm-firmware,libertas-firmware,mt7xxx-firmware,nvidia-gpu-firmware,nxpwireless-firmware,qcom-wwan-firmware,realtek-firmware,tiwilink-firmware' \
    @hardware-support \
    alsa-utils \
    pulseaudio-utils \
    pipewire-pulseaudio \
    pipewire-alsa \
    systemd-boot-unsigned \
    systemd-ukify \
    dracut \
    kmod \
    binutils \
    qrtr \
    pd-mapper \
    NetworkManager-wifi \
    glibc-langpack-en

# Qualcomm modem/audio services from onesaladleaf/pocketblue COPR (F45 builds)
echo 'Installing pocketblue services (rmtfs/tqftpserv/qbootctl/q6voiced)...'
dnf install -y --nogpgcheck \
    --releasever=45 \
    --setopt=install_weak_deps=False \
    --setopt=skip_if_unavailable=True \
    --repofrompath="pocketblue,https://download.copr.fedorainfracloud.org/results/onesaladleaf/pocketblue/fedora-45-aarch64/" \
    tqftpserv \
    rmtfs \
    qbootctl \
    q6voiced || echo 'WARNING: pocketblue install failed (non-fatal)'

systemctl enable NetworkManager 2>/dev/null || true
systemctl enable rmtfs 2>/dev/null || true
systemctl enable tqftpserv 2>/dev/null || true
systemctl enable q6voiced 2>/dev/null || true
systemctl enable qrtr-ns 2>/dev/null || true
systemctl enable pd-mapper 2>/dev/null || true

echo 'Creating user...'
# Fedora's default /etc/group has no 'storage'/'optical' (Debian/Arch-isms).
# Create them if missing so the -G membership stays valid on any base.
for g in wheel audio video storage optical; do
    getent group "$g" >/dev/null 2>&1 || groupadd "$g"
done
useradd -m -G wheel,audio,video,storage,optical -s /bin/bash user
echo 'user:fedora' | chpasswd
echo '%wheel ALL=(ALL) ALL' > /etc/sudoers.d/99-wheel-user
chmod 0440 /etc/sudoers.d/99-wheel-user

# Remove firmware blobs for chipsets this device doesn't have (mirrors the
# nabu-arch-images recipe). Fedora ships firmware as split subpackages, so the
# big x86/other-platform ones are already excluded at dnf time above; this rm
# is a secondary safety net for anything that sneaks in as a dependency.
# Keeps ath10k/ath11k/btqca/qcom (Qualcomm WiFi/BT/GPU for nabu); nabu-specific
# qcom/venus firmware comes from linux-firmware-xiaomi-nabu.
rm -rf /usr/lib/firmware/{intel,nvidia,amdgpu,mediatek,radeon,cirrus,brcm,ti-connectivity,i915}

echo 'Writing /etc/kernel/cmdline for UKI boot...'
mkdir -p /etc/kernel
echo 'root=LABEL=fedora_root rw quiet' > /etc/kernel/cmdline

dnf clean all
CHROOT_SETUP

chmod +x "$ROOTFS_DIR/root/setup.sh"
chroot "$ROOTFS_DIR" /bin/bash /root/setup.sh
rm -f "$ROOTFS_DIR/root/setup.sh"

# --- kernel: download + unpack ------------------------------------------------
mkdir -p kernel-pkgs
if [ -n "$NIGHTLY_KERNEL_URL" ]; then
    echo ">>> Downloading kernel zip: $NIGHTLY_KERNEL_URL"
    curl -fL "$NIGHTLY_KERNEL_URL" -o kernel-nightly.zip
    unzip -o kernel-nightly.zip -d kernel-pkgs/
else
    echo ">>> Downloading linux-nabu-$KERNEL_VERSION from nabu-pkgs release"
    curl -fL "https://github.com/${REPO_OWNER}/nabu-pkgs/releases/download/repo/linux-nabu-${KERNEL_VERSION}-aarch64.pkg.tar.xz" \
        -o "kernel-pkgs/linux-nabu-${KERNEL_VERSION}-aarch64.pkg.tar.xz"
fi

KERNEL_PKG=$(ls kernel-pkgs/linux-nabu-*.pkg.tar.* 2>/dev/null | grep -v headers | head -1 || true)
if [ -z "$KERNEL_PKG" ]; then
    echo "ERROR: no linux-nabu kernel package found in kernel-pkgs/" >&2
    ls -la kernel-pkgs/ || true
    exit 1
fi
echo ">>> Kernel package: $KERNEL_PKG"
unpack_arch_pkg "$KERNEL_PKG"

# derive kernel version from the extracted modules dir
KVER=$(ls "$ROOTFS_DIR/usr/lib/modules/" | head -1)
echo ">>> KVER = $KVER"

# --- firmware: linux-firmware-xiaomi-nabu (own nabu-pkgs release) -------------
echo ">>> Downloading linux-firmware-xiaomi-nabu"
FW_PKG_URL="https://github.com/${REPO_OWNER}/nabu-pkgs/releases/download/repo/linux-firmware-xiaomi-nabu-25.04.26-2-any.pkg.tar.xz"
curl -fL "$FW_PKG_URL" -o firmware-xiaomi-nabu.pkg.tar.xz
unpack_arch_pkg firmware-xiaomi-nabu.pkg.tar.xz

# --- kernel prep: vmlinuz into modules dir for dracut/ukify, depmod -----------
echo ">>> Preparing kernel: vmlinuz + depmod"
if [ -f "$ROOTFS_DIR/boot/vmlinuz-$KVER" ]; then
    cp -f "$ROOTFS_DIR/boot/vmlinuz-$KVER" "$ROOTFS_DIR/usr/lib/modules/$KVER/vmlinuz"
else
    echo "ERROR: vmlinuz-$KVER not found" >&2
    ls -la "$ROOTFS_DIR/boot/" || true
    exit 1
fi
chroot "$ROOTFS_DIR" depmod -a "$KVER" || echo 'WARNING: depmod failed'

# --- generate initramfs + UKI inside chroot ------------------------------------
echo ">>> Generating initramfs + UKI for $KVER"
cat > "$ROOTFS_DIR/root/mkuki.sh" <<'CHROOT_UKI'
set -e
KVER="$1"
echo 'Running dracut...'
dracut --kver "$KVER" --no-hostonly --no-machineid -f "/boot/initramfs-$KVER.img"
echo 'Running ukify...'
mkdir -p /boot/efi/EFI/fedora
ukify build \
    --linux="/usr/lib/modules/$KVER/vmlinuz" \
    --initrd="/boot/initramfs-$KVER.img" \
    --output="/boot/efi/EFI/fedora/fedora-$KVER.efi" \
    --cmdline="root=LABEL=fedora_root rw quiet" \
    --os-release=@/etc/os-release
ls -l "/boot/efi/EFI/fedora/"
if [ ! -f "/boot/efi/EFI/fedora/fedora-$KVER.efi" ]; then
    echo "ERROR: UKI not generated" >&2
    exit 1
fi
CHROOT_UKI

chmod +x "$ROOTFS_DIR/root/mkuki.sh"
chroot "$ROOTFS_DIR" /bin/bash /root/mkuki.sh "$KVER"
rm -f "$ROOTFS_DIR/root/mkuki.sh"

# --- dualboot bootmanager (rEFInd + AndroidBootPkg) into /boot/efi -------------
echo ">>> Installing efi-template (rEFInd dualboot bootmanager)"
EFI_TEMPLATE="$PWD/base/overlay/opt/nabu/efi-template/EFI"
if [ -d "$EFI_TEMPLATE" ]; then
    mkdir -p "$ROOTFS_DIR/boot/efi"
    cp -r "$EFI_TEMPLATE/." "$ROOTFS_DIR/boot/efi/"
else
    echo "WARNING: efi-template not found at $EFI_TEMPLATE"
fi

echo ">>> Cleaning up kernel pkg files"
rm -rf kernel-pkgs kernel-nightly.zip firmware-xiaomi-nabu.pkg.tar.xz

umount_chroot_fs
trap - EXIT
sync

# --- package EFI files ---------------------------------------------------------
echo ">>> Packaging EFI files"
EFI_DIR="$ROOTFS_DIR/boot/efi"
PROJECT_ROOT="$PWD"
if [ -d "$EFI_DIR" ] && [ -n "$(ls -A "$EFI_DIR")" ]; then
    echo "Found EFI files:"
    ls -lR "$EFI_DIR"
    (cd "$EFI_DIR" && zip -r "$PROJECT_ROOT/efi-files.zip" .)
    echo ">>> efi-files.zip created"

    # --- create flashable ESP image ------------------------------------------
    echo ">>> Creating flashable ESP image"
    ESP_IMAGE="$PROJECT_ROOT/flashable_esp.img"
    IMG_SIZE_BYTES=350105600
    LOGICAL_SECTOR_SIZE=4096
    SECTORS_PER_CLUSTER=1
    RESERVED_SECTORS=32
    HIDDEN_SECTORS=21234176
    VOLUME_LABEL="ESPNABU"
    VOLUME_ID="5C7A09AD"

    MOUNT_POINT=$(mktemp -d)

    echo ">>> [1/5] Creating empty image file..."
    truncate -s ${IMG_SIZE_BYTES} ${ESP_IMAGE}

    echo ">>> [2/5] Formatting image with precise device geometry..."
    mkfs.vfat \
        -F 32 \
        -S ${LOGICAL_SECTOR_SIZE} \
        -s ${SECTORS_PER_CLUSTER} \
        -R ${RESERVED_SECTORS} \
        -h ${HIDDEN_SECTORS} \
        -n "${VOLUME_LABEL}" \
        -i "${VOLUME_ID}" \
        -f 2 \
        ${ESP_IMAGE}

    echo ">>> [3/5] Mounting the image file..."
    mount -o loop ${ESP_IMAGE} ${MOUNT_POINT}

    echo ">>> [4/5] Copying EFI files..."
    cp -r ${EFI_DIR}/* ${MOUNT_POINT}/

    echo ">>> [5/5] Unmounting the image file..."
    umount ${MOUNT_POINT}
    rmdir ${MOUNT_POINT}

    echo ">>> Successfully created bootable ${ESP_IMAGE}"
    zstd -T0 -v -f ${ESP_IMAGE}
else
    echo "ERROR: EFI directory '$EFI_DIR' is empty or does not exist." >&2
    ls -lR "$ROOTFS_DIR/boot" || true
    exit 1
fi

echo "======================================================================"
echo "Base rootfs ready:"
du -sh "$ROOTFS_DIR"
ls -la efi-files.zip flashable_esp.img.zst
echo "======================================================================"