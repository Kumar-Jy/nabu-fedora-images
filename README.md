# nabu-fedora-images

Fedora Linux for Xiaomi Pad 5 (nabu), built as **flashable installer ZIPs**
in the same style as [Nabu-arch-images](https://github.com/Kumar-Jy/Nabu-arch-images).

- Target: Fedora 45 (beta) aarch64
- Kernel: [linux-nabu](https://github.com/Kumar-Jy/linux-nabu) 6.14.11 (default
  `6.14.11-8` from the [nabu-pkgs](https://github.com/Kumar-Jy/nabu-pkgs)
  release, or a nightly kernel ZIP URL)
- Variants: `gnome`, `kde`, `niri`
- Output: flashable ZIP per variant + ESP image + EFI files

## How it works

| Workflow | Purpose |
|---|---|
| `1. Build Builder Image` | Builds `ghcr.io/<owner>/fedora-nabu-builder:45` (Fedora 45 tooling container) |
| `2. Build Installers` | Base rootfs → variant rootfs → flashable ZIPs → optional GitHub release |

Pipeline (mirrors the reference [jhuang6451/nabu_fedora](https://github.com/jhuang6451/nabu_fedora) flow):

1. `scripts/1-create-rootfs-base.sh` bootstraps a Fedora 45 aarch64 rootfs
   (dnf `--installroot`), installs core + Qualcomm services (qrtr, pd-mapper,
   rmtfs, tqftpserv, qbootctl, q6voiced from the `onesaladleaf/pocketblue`
   COPR), extracts the **linux-nabu kernel package** into the rootfs, generates
   a **UKI** with `dracut` + `systemd-ukify`, bundles the rEFInd dualboot
   bootmanager, and produces `efi-files.zip` + `flashable_esp.img.zst`.
2. `scripts/2-create-rootfs-<variant>.sh` copies the base rootfs, installs the
   desktop environment from Fedora repos, and packs a minimized **ext4
   `images/rootfs.img`** (label `fedora_root`).
3. The workflow assembles each variant into a flashable ZIP:
   `bin/`, `DBKP/`, `efi/`, `images/rootfs.img`, `images/esp.img`,
   `installer/`, `META-INF/`, `flash-linux.bat`, `flash-linux.sh`.
4. `scripts/3-create-release.sh` (optional) publishes a GitHub Release.

## Flashing

Unzip the installer ZIP and run from the repo folder:

```sh
./flash-linux.sh
# or, on Windows: flash-linux.bat
```

The script erases and flashes:

- `linux` partition ← `images/rootfs.img` (Fedora rootfs)
- `esp` partition ← `images/esp.img` (EFI system partition, label `ESPNABU`)

Boot into the rEFInd dualboot menu, pick Fedora (UKI) or Android.

> ⚠️ Flashing overwrites the current `linux` and `esp` partitions.

## Building

1. Push to a GitHub repo, run **`1. Build Builder Image`** once.
2. Run **`2. Build Installers`** with inputs:
   - `variant`: `all` (default), `gnome`, `kde`, `niri`
   - `build_version`: e.g. `45`
   - `kernel_version`: pinned kernel (e.g. `6.14.11-8`); empty = latest in `[nabu]`
   - `nightly_kernel_url`: nightly kernel ZIP URL (takes priority over `kernel_version`)

## Notes

- The kernel is installed from the Arch package layout (extracted `.pkg.tar.xz`
  into the rootfs). Firmware comes from `linux-firmware-xiaomi-nabu` and the
  kernel package's own `etc/modprobe.d/99-iris-vaapi.conf`.
- jhuang6451's `nabu_fedora_packages` COPR has no Fedora-45 builds yet, so the
  configs/firmware/dualboot helper packages are not used; equivalent bits are
  produced in-repo (efi-template bootmanager, pocketblue services, UKI).
- Btrfs is not used (plain ext4 `fedora_root` rootfs, matching the classic
  flashable-zip installer style).

## License

MIT — see [LICENSE](LICENSE).