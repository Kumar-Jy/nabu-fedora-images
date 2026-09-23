# Fedora 45 builder image for nabu-fedora-images
# Contains the tooling needed to build aarch64 rootfs images inside
# GitHub Actions (runs on ubuntu-24.04-arm, arm64 native).

FROM fedora:45

RUN dnf config-manager addrepo --from-repofile=https://cli.github.com/packages/rpm/gh-cli.repo && \
    dnf makecache && \
    dnf install -y \
    coreutils \
    dnf-utils \
    dnf-plugins-core \
    dnf5-plugins \
    gh \
    qemu-user-static \
    tar \
    gzip \
    xz \
    zstd \
    zip \
    unzip \
    curl \
    wget \
    findutils \
    util-linux \
    rsync \
    gawk \
    dosfstools \
    mtools \
    e2fsprogs \
    grub2-tools \
    grub2-efi-aa64-modules \
    systemd-container \
    rpm-build \
    cpio \
    jq \
    && dnf clean all