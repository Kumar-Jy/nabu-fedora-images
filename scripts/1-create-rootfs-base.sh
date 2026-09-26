#!/bin/bash

# 1-create-rootfs-base.sh - Fedora 45 aarch64 base rootfs for nabu (Xiaomi Pad 5).
#
# Produces fedora-rootfs-base/, efi-files.zip and flashable_esp.img.zst.
# The variant scripts consume fedora-rootfs-base/.
#
# Kernel: $NIGHTLY_KERNEL_URL (ZIP of linux-nabu pkgs) if set, else
# linux-nabu-$KERNEL_VERSION from the nabu-pkgs release.
#
# Env: BUILD_VERSION, KERNEL_VERSION, NIGHTLY_KERNEL_URL, FIRMWARE_PKG_VERSION

set -e

ROOTFS_DIR="$PWD/fedora-rootfs-base"
RELEASEVER="45"
ARCH="aarch64"
BUILD_VERSION="${BUILD_VERSION}"
KERNEL_VERSION="${KERNEL_VERSION:-6.14.11-10}"
NIGHTLY_KERNEL_URL="${NIGHTLY_KERNEL_URL:-}"
FIRMWARE_PKG_VERSION="${FIRMWARE_PKG_VERSION:-25.04.26-2}"
REPO_OWNER="${GITHUB_REPOSITORY_OWNER:-Kumar-Jy}"
NABU_PKG_URL="https://github.com/${REPO_OWNER}/nabu-pkgs/releases/download/repo"

# --- helpers
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

# current version of a package in the nabu-pkgs repo, from its repo db
repo_pkg_version() {
    local db
    db=$(mktemp)
    if curl -fsSL -o "$db" "$NABU_PKG_URL/nabu.db"; then
        tar -tzf "$db" | sed -n "s|^$1-\\(.*\\)/$|\\1|p" | head -1
    fi
    rm -f "$db"
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

# --- bootstrap base system
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

# --- main installation inside chroot
echo ">>> Configuring system inside chroot"
cat > "$ROOTFS_DIR/root/setup.sh" <<'CHROOT_SETUP'
set -e
set -o pipefail

# the updates repo can be 404 on F45 beta; keep going regardless
dnf config-manager setopt fedora.skip_if_unavailable=True 2>/dev/null || true

echo 'Installing core packages...'
dnf install -y --nogpgcheck \
    --releasever=45 \
    --setopt=install_weak_deps=False \
    --setopt=skip_if_unavailable=True \
    --allowerasing \
    @core

echo 'Installing hardware support + nabu services...'
# nabu parity with nabu-arch-images: sensors + camera
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
    systemd-pam \
    dracut \
    kmod \
    binutils \
    qrtr \
    pd-mapper \
    NetworkManager-wifi \
    glibc-langpack-en \
    iio-sensor-proxy \
    libcamera \
    libcamera-ipa \
    libcamera-tools \
    libusb1 \
    zram-generator

# Qualcomm services from the pocketblue COPR. Fatal on purpose: without rmtfs
# there is no DSP firmware, so no audio. q6voiced is not enabled - snd-sm8150
# does its own routing.
echo 'Installing pocketblue services (rmtfs/tqftpserv/qbootctl)...'
dnf install -y --nogpgcheck \
    --releasever=45 \
    --setopt=install_weak_deps=False \
    --setopt=skip_if_unavailable=True \
    --repofrompath="pocketblue,https://download.copr.fedorainfracloud.org/results/onesaladleaf/pocketblue/fedora-45-aarch64/" \
    tqftpserv \
    rmtfs \
    qbootctl

# Services are enabled in the finalize step, once all payloads are unpacked.

echo 'Setting HandlePowerKey=ignore (tablet: power key must not shutdown while fiddling)...'
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/10-nabu-power.conf <<'EOF'
[Login]
HandlePowerKey=ignore
EOF

echo 'Creating user...'
# Create storage/optical groups if missing so the -G membership is valid.
for g in wheel audio video storage optical; do
    getent group "$g" >/dev/null 2>&1 || groupadd "$g"
done
useradd -m -G wheel,audio,video,storage,optical -s /bin/bash user
echo 'user:fedora' | chpasswd
echo '%wheel ALL=(ALL) ALL' > /etc/sudoers.d/99-wheel-user
chmod 0440 /etc/sudoers.d/99-wheel-user

# the README tells people to run this first, so it has to be on the device
install -Dm755 /root/nabu-diag.sh /usr/bin/nabu-diag
install -Dm755 /root/nabu-diag.sh /home/user/nabu-diag.sh

# Drop firmware for chipsets nabu doesn't have. dnf already excluded most of it;
# this catches stragglers pulled in as deps.
rm -rf /usr/lib/firmware/{intel,nvidia,amdgpu,mediatek,radeon,cirrus,brcm,ti-connectivity,i915}

echo 'Writing /etc/fstab...'
# Labels come from the install scripts, so this works as-is.
# No swap: zram-generator handles that.
cat > /etc/fstab <<'EOF'
LABEL=fedora_root  /        ext4  defaults                 0 1
LABEL=ESPNABU      /boot/efi vfat umask=0077,shortname=winnt 0 2
EOF

echo 'Configuring SELinux for this kernel...'
# linux-nabu has no CONFIG_SECURITY_SELINUX, so getenforce is permanently
# "disabled" and /.autorelabel would never be consumed. Ship it disabled.
mkdir -p /etc/selinux/targeted
ln -sfn policy /etc/selinux/targeted/active
rm -f /.autorelabel
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
cat > /etc/nabu-selinux-note <<'EOF'
linux-nabu has no SELinux support: CONFIG_SECURITY_SELINUX is not compiled in
and CONFIG_LSM does not list selinux. `getenforce` therefore always reports
"disabled" and there is no MAC enforcement on this image. This is expected and
is a property of the kernel, not a misconfiguration.
EOF

echo 'Writing /etc/kernel/cmdline for UKI boot...'
mkdir -p /etc/kernel
echo 'root=LABEL=fedora_root rw quiet systemd.gpt_auto=no acpi=off fw_devlink=permissive' > /etc/kernel/cmdline

# The sm8150 boot chain hands the kernel no device tree, so the nabu DTB is
# embedded in the UKI - without it initramfs cannot find root.
cat > /etc/kernel/uki.conf <<'EOF'
[UKI]
DeviceTree=/boot/dtb-linux-nabu
EOF

dnf clean all
CHROOT_SETUP

chmod +x "$ROOTFS_DIR/root/setup.sh"
install -Dm755 "$PWD/scripts/nabu-diag.sh" "$ROOTFS_DIR/root/nabu-diag.sh"
chroot "$ROOTFS_DIR" /bin/bash /root/setup.sh
rm -f "$ROOTFS_DIR/root/setup.sh" "$ROOTFS_DIR/root/nabu-diag.sh"

# --- kernel: download + unpack
mkdir -p kernel-pkgs
if [ -n "$NIGHTLY_KERNEL_URL" ]; then
    echo ">>> Downloading kernel zip: $NIGHTLY_KERNEL_URL"
    curl -fL "$NIGHTLY_KERNEL_URL" -o kernel-nightly.zip
    unzip -o kernel-nightly.zip -d kernel-pkgs/
else
    # empty or "latest" -> whatever the nabu-pkgs repo currently serves
    if [ -z "$KERNEL_VERSION" ] || [ "$KERNEL_VERSION" = "latest" ]; then
        KERNEL_VERSION=$(repo_pkg_version linux-nabu)
        [ -n "$KERNEL_VERSION" ] || { echo "ERROR: no linux-nabu in the nabu-pkgs repo db" >&2; exit 1; }
        echo ">>> KERNEL_VERSION=latest resolved to $KERNEL_VERSION"
    fi
    echo ">>> Downloading linux-nabu-$KERNEL_VERSION from nabu-pkgs release"
    curl -fL "${NABU_PKG_URL}/linux-nabu-${KERNEL_VERSION}-aarch64.pkg.tar.xz" \
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

# --- firmware: linux-firmware-xiaomi-nabu (own nabu-pkgs release)
echo ">>> Downloading linux-firmware-xiaomi-nabu"
FW_PKG_URL="${NABU_PKG_URL}/linux-firmware-xiaomi-nabu-${FIRMWARE_PKG_VERSION}-any.pkg.tar.xz"
curl -fL "$FW_PKG_URL" -o firmware-xiaomi-nabu.pkg.tar.xz
unpack_arch_pkg firmware-xiaomi-nabu.pkg.tar.xz

# --- hexagonfs mirror
# The package ships the Hexagon tree under /usr/share/qcom. Arch's hexagonrpcd
# mirrors it to /lib/firmware/hexagonfs; Fedora has no such package.
echo ">>> Mirroring /usr/share/qcom/... -> /usr/lib/firmware/hexagonfs"
NABU_SHARE="$ROOTFS_DIR/usr/share/qcom/sm8150/xiaomi/nabu"
NABU_LIBFW="$ROOTFS_DIR/usr/lib/firmware"
if [ -d "$NABU_SHARE/socinfo" ] || [ -d "$NABU_SHARE/sensors" ]; then
    mkdir -p "$NABU_LIBFW/hexagonfs"
    cp -a "$NABU_SHARE/." "$NABU_LIBFW/hexagonfs/"
    for d in sensors socinfo; do
        [ -d "$NABU_LIBFW/hexagonfs/$d" ] || continue
        ln -sfn "../../../../hexagonfs/$d" "$NABU_LIBFW/qcom/sm8150/xiaomi/nabu/$d"
    done
    echo "    hexagonfs: $(ls "$NABU_LIBFW/hexagonfs")"
    echo "    symlinks: $(ls -l "$NABU_LIBFW/qcom/sm8150/xiaomi/nabu" | grep -c '^l')"
else
    echo "WARNING: $NABU_SHARE not found - hexagonfs (socinfo/sensors) will be absent." >&2
    echo "WARNING: audio fastrpc and DSP sensors will not work." >&2
fi

# --- prune firmware for platforms nabu does not have
# Fedora ships blobs for every SoC the kernel covers (qcom/ alone is ~208 MB).
# dracut --no-hostonly copies firmware into the initrd, so this is what keeps the
# UKI small enough for the ESP. Whole subdirs only - the Adreno blobs sit at
# qcom/ top level.
echo ">>> Pruning firmware for other platforms"
KEEP_FW_DIRS="sm8150 venus-6.0"
for d in "$ROOTFS_DIR"/usr/lib/firmware/qcom/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    case " $KEEP_FW_DIRS " in
        *" $name "*) continue ;;
    esac
    echo "    rm -rf qcom/$name"
    rm -rf "$d"
done
echo "    firmware now: $(du -sh "$ROOTFS_DIR/usr/lib/firmware" 2>/dev/null | cut -f1)"

# --- displaylink: evdi module (built for THIS kernel) + userland
# evdi is built in the chroot against these kernel headers, so no dkms on device.
echo ">>> Installing DisplayLink (evdi built for $KVER)"
DL_PKG_VERSION="6.3-1"
EVDI_DKMS_VERSION="1.15.0-1"
PMAC_PKG_VERSION="1-2"
ARCHPKG="aarch64.pkg.tar.xz"

curl -fL "${NABU_PKG_URL}/displaylink-${DL_PKG_VERSION}-${ARCHPKG}" -o displaylink.pkg.tar.xz
curl -fL "${NABU_PKG_URL}/evdi-dkms-${EVDI_DKMS_VERSION}-${ARCHPKG}" -o evdi-dkms.pkg.tar.xz
unpack_arch_pkg displaylink.pkg.tar.xz
unpack_arch_pkg evdi-dkms.pkg.tar.xz

# stable wifi MAC + pin the interface to wlan0 (upstream would call it wld0)
echo ">>> Installing nabu-pmac (stable WiFi MAC, wlan0 naming)"
curl -fL "${NABU_PKG_URL}/nabu-pmac-${PMAC_PKG_VERSION}-any.pkg.tar.xz" -o nabu-pmac.pkg.tar.xz
unpack_arch_pkg nabu-pmac.pkg.tar.xz

# headers for THIS kernel: from the nightly zip if present, else the release
HEADERS_PKG=$(ls kernel-pkgs/linux-nabu-headers-*.pkg.tar.* 2>/dev/null | head -1 || true)
if [ -z "$HEADERS_PKG" ]; then
    echo ">>> Downloading linux-nabu-headers-${KERNEL_VERSION}"
    curl -fL "${NABU_PKG_URL}/linux-nabu-headers-${KERNEL_VERSION}-${ARCHPKG}" -o headers.pkg.tar.xz
    HEADERS_PKG="headers.pkg.tar.xz"
fi
unpack_arch_pkg "$HEADERS_PKG"

cat > "$ROOTFS_DIR/root/mkevdi.sh" <<'CHROOT_EVDI'
set -e
set -o pipefail
KVER="$1"
echo 'Installing C toolchain for the evdi build...'
dnf install -y --nogpgcheck \
    --releasever=45 \
    --setopt=install_weak_deps=False \
    --setopt=skip_if_unavailable=True \
    gcc make
echo "Building evdi against the nabu kernel ($KVER)..."
cd /usr/src/evdi-1.15.0
make -j"$(nproc)" KDIR="/usr/lib/modules/${KVER}/build"
mkdir -p "/usr/lib/modules/${KVER}/updates/dkms"
install -m644 evdi.ko "/usr/lib/modules/${KVER}/updates/dkms/evdi.ko"
echo 'Enabling DisplayLink manager service...'
systemctl enable displaylink
CHROOT_EVDI

chmod +x "$ROOTFS_DIR/root/mkevdi.sh"
chroot "$ROOTFS_DIR" /bin/bash /root/mkevdi.sh "$KVER"
rm -f "$ROOTFS_DIR/root/mkevdi.sh"

# rootfs hygiene: kernel headers + module source are build-time only
rm -rf "$ROOTFS_DIR/usr/src/evdi-1.15.0" "$ROOTFS_DIR/usr/lib/modules/$KVER/build"

# --- apply base/overlay into the rootfs (nabu parity files)
# Before dracut: the overlay carries /etc/dracut.conf.d and firmware, which only
# reach the initramfs if already in place. efi-template goes to the ESP below.
echo ">>> Applying base/overlay into rootfs (dracut config, firmware, libcamera tunings)"
if [ -d "$PWD/base/overlay" ]; then
    tar -C "$PWD/base/overlay" --exclude='opt/nabu/efi-template' -cf - . \
        | tar -C "$ROOTFS_DIR" -xf -
else
    echo "WARNING: base/overlay not found at $PWD/base/overlay" >&2
fi

# --- kernel prep: vmlinuz into modules dir for dracut/ukify, depmod
echo ">>> Preparing kernel: vmlinuz + depmod"
if [ -f "$ROOTFS_DIR/boot/vmlinuz-$KVER" ]; then
    cp -f "$ROOTFS_DIR/boot/vmlinuz-$KVER" "$ROOTFS_DIR/usr/lib/modules/$KVER/vmlinuz"
else
    echo "ERROR: vmlinuz-$KVER not found" >&2
    ls -la "$ROOTFS_DIR/boot/" || true
    exit 1
fi
chroot "$ROOTFS_DIR" depmod -a "$KVER" || echo 'WARNING: depmod failed'

# --- generate initramfs + UKI inside chroot
echo ">>> Generating initramfs + UKI for $KVER"
cat > "$ROOTFS_DIR/root/mkuki.sh" <<'CHROOT_UKI'
set -e
KVER="$1"
echo 'Running dracut...'
# dracut embeds the machine-id in the initrd; a container build has none.
if [ ! -s /etc/machine-id ]; then
    echo "    generating /etc/machine-id"
    systemd-machine-id-setup >/dev/null 2>&1 || true
fi
dracut --kver "$KVER" --no-hostonly -f "/boot/initramfs-$KVER.img"
echo 'Running ukify...'
mkdir -p /boot/efi/EFI/fedora
# ukify 262 has no --machine-id flag; use --uname.
ukify build \
    --linux="/usr/lib/modules/$KVER/vmlinuz" \
    --initrd="/boot/initramfs-$KVER.img" \
    --output="/boot/efi/EFI/fedora/fedora-$KVER.efi" \
    --cmdline="root=LABEL=fedora_root rw quiet systemd.gpt_auto=no acpi=off fw_devlink=permissive" \
    --devicetree=/boot/dtb-linux-nabu \
    --uname="$KVER" \
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

# (base/overlay went in before depmod/dracut, so its dracut config and
#  firmware land in the initramfs.)

# --- finalize: enable services
# Last, so every payload's units are on disk. rmtfs and tqftpserv are required:
# no DSP firmware (audio/wifi/bt) and no touch firmware without them.
echo ">>> Finalizing: enabling services"
for u in NetworkManager rmtfs tqftpserv qbootctl displaylink nabu-pmac; do
    if systemctl --root="$ROOTFS_DIR" enable "$u" >/dev/null 2>&1; then
        echo "    enabled  $u"
    else
        echo "    FAILED   $u (no unit file)" >&2
    fi
done
for u in rmtfs tqftpserv; do
    if ! systemctl --root="$ROOTFS_DIR" is-enabled "$u" >/dev/null 2>&1; then
        echo "ERROR: required service '$u' is not enabled - refusing to ship." >&2
        exit 1
    fi
done

# --- assert the image is actually complete
# Missing DSP firmware ships silently: every DSP stays dead and takes wifi,
# bluetooth and audio while display and touch keep working.
echo ">>> Verifying image completeness"
FW="$ROOTFS_DIR/usr/lib/firmware"

# Firmware may legitimately ship compressed, so accept any of the three forms.
fw_present() {
    [ -e "$FW/$1" ] || [ -e "$FW/$1.xz" ] || [ -e "$FW/$1.zst" ]
}

REQUIRED_FW=(
    # named by firmware-name in /boot/dtb-*-nabu
    novatek/novatek_nt36523_fw.bin
    qcom/sm8150/xiaomi/nabu/a640_zap.mbn
    qcom/sm8150/xiaomi/nabu/adsp.mbn
    qcom/sm8150/xiaomi/nabu/cdsp.mbn
    qcom/sm8150/xiaomi/nabu/modem.mbn
    qcom/sm8150/xiaomi/nabu/slpi_nb.mbn
    qcom/sm8150/xiaomi/nabu/venus.mbn
    # remoteproc blobs the DT starts before root is mounted. wlanmdsp.mbn is a
    # remoteproc, not an ath10k file - ath10k only requests firmware-<ver>.bin
    # and board-*.bin under its own WCN3990 dir.
    qcom/sm8150/xiaomi/nabu/wlanmdsp.mbn
    # requested at runtime by the wifi driver (ath10k WCN3990 hw1.0)
    ath10k/WCN3990/hw1.0/board-2.bin
    ath10k/WCN3990/hw1.0/firmware-5.bin
    qca/crbtfw32.tlv
    qca/crnv32.bin
    regulatory.db
    # Hexagon DSP tree mirrored from /usr/share/qcom
    hexagonfs/socinfo/soc_id
    hexagonfs/sensors/sns_reg.conf
)
REQUIRED_PATHS=(
    etc/fstab
    etc/selinux/targeted/active
    etc/selinux/targeted/policy
    etc/nabu-selinux-note
    boot/dtb-linux-nabu
    usr/bin/nabu-pmac-set
    etc/systemd/network/10-wlan.link
    usr/bin/nabu-diag
)

VERIFY_FAIL=0
for f in "${REQUIRED_FW[@]}"; do
    if fw_present "$f"; then
        echo "    ok       fw/$f"
    else
        echo "    MISSING  fw/$f" >&2
        VERIFY_FAIL=1
    fi
done
for p in "${REQUIRED_PATHS[@]}"; do
    if [ -e "$ROOTFS_DIR/$p" ]; then
        echo "    ok       /$p"
    else
        echo "    MISSING  /$p" >&2
        VERIFY_FAIL=1
    fi
done
# hexagonfs must be reachable through the relative symlinks the drivers use.
for l in sensors socinfo; do
    if [ -d "$FW/qcom/sm8150/xiaomi/nabu/$l" ]; then
        echo "    ok       fw/qcom/sm8150/xiaomi/nabu/$l -> hexagonfs"
    else
        echo "    MISSING  fw/qcom/sm8150/xiaomi/nabu/$l (hexagonfs link)" >&2
        VERIFY_FAIL=1
    fi
done
if [ "$VERIFY_FAIL" -ne 0 ]; then
    cat >&2 <<'MSG'

ERROR: image verification failed. Do NOT flash it.
       See the MISSING lines above; a missing DSP blob takes out
       wifi + bluetooth + audio together.
MSG
    exit 1
fi
echo "    all required firmware and config present"

# --- assert the DSP firmware actually made it into the initrd
# The DT starts the slpi/cdsp/adsp remoteprocs at ~4s, before root is mounted,
# so blobs in the rootfs are useless - they must be in the initrd. `modem` starts
# after switch_root, which is why it worked and masked this.
echo ">>> Verifying initrd carries the Hexagon DSP firmware"
INITRD="$ROOTFS_DIR/boot/initramfs-$KVER.img"
# The initrd is compressed, so decompress it once and search the scratch copy.
INITRD_TXT="$(mktemp)"
if   zstd -dc "$INITRD" > "$INITRD_TXT" 2>/dev/null \
  || xz  -dc "$INITRD" > "$INITRD_TXT" 2>/dev/null \
  || gzip -dc "$INITRD" > "$INITRD_TXT" 2>/dev/null \
  || lz4 -dc "$INITRD" > "$INITRD_TXT" 2>/dev/null \
  || cp "$INITRD" "$INITRD_TXT"; then
    :
else
    echo "ERROR: could not decompress $INITRD to verify it" >&2
    rm -f "$INITRD_TXT"
    exit 1
fi
INITRD_MISSING=0
for f in slpi_nb cdsp adsp venus modem wlanmdsp; do
    if grep -aq "qcom/sm8150/xiaomi/nabu/$f.mbn" "$INITRD_TXT"; then
        echo "    ok       initrd: $f.mbn"
    else
        echo "    MISSING  initrd: $f.mbn" >&2
        INITRD_MISSING=1
    fi
done
rm -f "$INITRD_TXT"
if [ "$INITRD_MISSING" -ne 0 ]; then
    cat >&2 <<'MSG'

ERROR: the initrd does not carry the nabu Hexagon DSP firmware.
       The image would boot with wifi, bluetooth and audio all dead.
       Check that base/overlay/etc/dracut.conf.d/99-nabu.conf install_items
       lists these blobs and that the overlay is applied BEFORE dracut runs.
MSG
    exit 1
fi
echo "    initrd size: $(du -h "$INITRD" | cut -f1)"

# --- dualboot bootmanager (rEFInd + AndroidBootPkg) into /boot/efi
echo ">>> Installing efi-template (rEFInd dualboot bootmanager)"
EFI_TEMPLATE="$PWD/base/overlay/opt/nabu/efi-template/EFI"
if [ -d "$EFI_TEMPLATE" ]; then
    mkdir -p "$ROOTFS_DIR/boot/efi"
    cp -r "$EFI_TEMPLATE/." "$ROOTFS_DIR/boot/efi/"
else
    echo "WARNING: efi-template not found at $EFI_TEMPLATE"
fi

echo ">>> Cleaning up kernel pkg files"
rm -rf kernel-pkgs kernel-nightly.zip firmware-xiaomi-nabu.pkg.tar.xz \
    displaylink.pkg.tar.xz evdi-dkms.pkg.tar.xz headers.pkg.tar.xz

umount_chroot_fs
trap - EXIT
sync

# --- package EFI files
echo ">>> Packaging EFI files"
EFI_DIR="$ROOTFS_DIR/boot/efi"
PROJECT_ROOT="$PWD"
if [ -d "$EFI_DIR" ] && [ -n "$(ls -A "$EFI_DIR")" ]; then
    echo "Found EFI files:"
    ls -lR "$EFI_DIR"
    (cd "$EFI_DIR" && zip -r "$PROJECT_ROOT/efi-files.zip" .)
    echo ">>> efi-files.zip created"

    # --- create flashable ESP image
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
