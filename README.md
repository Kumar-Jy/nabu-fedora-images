# nabu-fedora-images

Fedora 45 (beta) aarch64 for Xiaomi Pad 5 (nabu). Built as flashable zip
installers in the same style as [Nabu-arch-images](https://github.com/Kumar-Jy/Nabu-arch-images).

Variants: **gnome**, **kde**, **niri**. Kernel: linux-nabu. rEFInd dualboot
with Android.

---

## Requirements

- Xiaomi Pad 5 (nabu)
- Unlocked bootloader
- [TWRP](https://github.com/Kumar-Jy/twrp_device_xiaomi_nabu/releases/tag/mod-hybrid) custom recovery
- Installer zip from [Releases](https://github.com/Kumar-Jy/nabu-fedora-images/releases)

---

## Installation

### Creating Partitions (if not already present)

If your device doesn't have the required `esp` and `linux` partitions, create them first:

1. **Boot into TWRP** from your PC:
   ```bash
   fastboot boot twrp.img
   ```

2. **Open TWRP Terminal**: In TWRP, go to **Advanced > Terminal**

3. **Run the partition tool**:
   ```bash
   partition
   ```
   Follow the on-screen instructions to create the `win` (optional), `linux` and `esp` partitions.

4. **Reboot back into TWRP** after partitioning: Go to **Reboot > Recovery**

5. Proceed to the installation steps below.

### Triple Boot (Windows + Android + Linux)

1. **Install Windows first** — Set up Windows on the `win` partition
2. **Return to Android** — Boot back into Android to ensure it's working
3. **Flash the Linux installer** — Boot into TWRP and flash the Fedora installer zip
4. **Reboot** — rEFInd will show all three boot options (Windows, Android, Linux)

### Fedora Linux Install (Single Boot or Dual Boot)

1. **Download** the latest installer from [Releases](https://github.com/Kumar-Jy/nabu-fedora-images/releases):
   - `nabu-fedora-45-gnome-installer.zip` — GNOME Desktop
   - `nabu-fedora-45-kde-installer.zip` — KDE Plasma Desktop
   - `nabu-fedora-45-niri-installer.zip` — Niri compositor

2. **Boot into TWRP**: Power off the tablet, hold **Power + Volume Up**

3. **Flash the installer zip**: In TWRP, tap **Install**, navigate to the zip, swipe to confirm

4. **What the installer does**:
   - Formats `/dev/block/by-name/linux` with ext4
   - Extracts the rootfs image onto the partition
   - Sets up ESP with rEFInd and the Unified Kernel Image
   - Patches the `boot` partition with DBKP + UEFI payload

5. **Reboot**: Select **Reboot > System**

6. **Default credentials**: `user` / `fedora`

### Dual/Triple Boot with Android/Windows

- The `boot` partition is patched with DualBootKernelPatcher + UEFI payload
- On first UEFI boot, `installer/install.bat` runs in WinPE to reconfigure Windows BCD
- rEFInd provides a boot menu to choose between Android, Fedora and Windows