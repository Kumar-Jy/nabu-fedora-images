# nabu-fedora-images

Fedora 45 (beta) aarch64 for Xiaomi Pad 5 (nabu). Built as flashable zip
installers in the same style as [Nabu-arch-images](https://github.com/Kumar-Jy/Nabu-arch-images).

Variants: **gnome**, **kde**, **niri**. Kernel: linux-nabu (default `6.14.11-8`,
or a nightly ZIP URL). rEFInd dualboot with Android.

## Build

Run the workflows in order:

1. `1. Build Builder Image` — once, builds `ghcr.io/kumar-jy/fedora-nabu-builder:45`
2. `Build installers` — base rootfs → variant rootfs → flashable zips

`Build installers` inputs:

| input | default | notes |
|---|---|---|
| `variant` | `all` | `all` / `gnome` / `kde` / `niri` |
| `build_version` | `45` | release tag uses it |
| `kernel_version` | `6.14.11-8` | empty = latest in [nabu] |
| `nightly_kernel_url` | empty | nightly kernel ZIP, beats `kernel_version` |
| `trigger_release` | off | also publish a GitHub release |

## Flash

Unzip the installer and run:

```sh
./flash-linux.sh        # or flash-linux.bat on Windows
```

It erases and flashes `images/rootfs.img` → `linux` (ext4, label `fedora_root`)
and `images/esp.img` → `esp` (EFI, label `ESPNABU`). Reboot into rEFInd and
pick Fedora or Android.

> ⚠️ Overwrites the current `linux` and `esp` partitions.

## Notes

- Non-atomic ext4 rootfs (no bootc/btrfs).
- Kernel + firmware are the Arch packages from
  [nabu-pkgs](https://github.com/Kumar-Jy/nabu-pkgs) releases; UKI is built
  with dracut + ukify. jhuang6451's Fedora COPR is empty on F45, so the
  bootloader/config/firmware bits are built in-repo instead; Qualcomm services
  (rmtfs/tqftpserv/qbootctl/q6voiced) come from
  [onesaladleaf/pocketblue](https://copr.fedorainfracloud.org/coprs/onesaladleaf/pocketblue/).

## License

MIT