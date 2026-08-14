# Boot and Installation Flow

## Before running setup

Boot the Ubuntu live medium in UEFI mode and start Ubiquity. Select manual
partitioning and install Ubuntu with this layout:

1. `/dev/sda1` reserved for the rescue system;
2. `/dev/sda2` as the FAT32 EFI System Partition mounted at `/boot/efi`;
3. `/dev/sda3` as the unencrypted Btrfs root mounted at `/`.

The initial rescue partition must be large enough for at least 7168 MiB of FAT
rescue data plus a separate writable partition of at least 512 MiB. Complete the
Ubiquity installation but remain in the
same live session. The scripts expect `/target`, `/target/boot/efi` and `/cdrom`
to remain available.

Run `setup.sh` as root. When `setup.conf` is absent, the grouped wizard uses its
built-in defaults, generates and validates the protected local
configuration, displays its non-secret values and asks whether installation
should proceed. The defaults target `/dev/sda1`, `/dev/sda2` and `/dev/sda3`.

## Installation sequence

The outer live-session phase performs these operations in order:

1. Validate root execution and configuration.
2. Convert the Ubiquity Btrfs layout into the configured suite hierarchy and create
   the dedicated data subvolumes and swap file.
3. Shrink Btrfs, encrypt `/dev/sda3` in place as LUKS2, open it as
   `/dev/mapper/root`, remount the target and expand Btrfs.
4. Rewrite the target's crypttab and fstab.
5. Prepare target bind mounts and copy the repository into the installed system.
6. Enter a mount-isolated chroot and run `setup.sh //inner`.

The inner phase then:

1. starts the required D-Bus service and clears the old suite-specific EFI
   directory;
2. updates packages and optionally pre-downloads them;
3. installs initramfs cryptsetup support;
4. detects the firmware mode and configures Secure Boot, rEFInd and fwupd;
5. configures Snapper and, when enabled, installs the snapshot-menu dracut
   module;
6. configures kernel-install, dracut and ukify, generates and validates UKIs;
7. optionally installs TPM integration without enrolling it.

On return, the outer phase splits the reserved rescue range, creates the ext4
`writable` partition, formats the resized rescue range as FAT and copies
`/cdrom` into it. It then recursively unmounts the target and closes the `root`
mapping as the final cleanup phase.

## Rescue boot

The resized rescue partition contains a copy of `/cdrom/casper` on FAT32. Its
GRUB Casper entries include `persistent`. A second partition created from the
released trailing range is formatted ext4 with label `writable` and supplies
persistence.

The rescue system is independent from the installed root and remains usable
when LUKS unlocking or the installed boot chain needs repair. Its persistent
data is not encrypted by the root LUKS container.

Root, home, logs, containers and swap of the installed operating system are
encrypted. Its ESP is the only unencrypted partition in the normal boot chain;
the separate rescue system is intentionally outside this FDE boundary.

After the installed system has booted, `setup.sh --install-rescue-live` runs
only the rescue phase using `rescue_dev` from `setup.conf`. Its live source
defaults to `/cdrom` and can be overridden with `RESCUE_SOURCE_DIR`. It does not
enter root conversion or the target chroot, but retains the exact-device
confirmation because the operation is destructive.

## Installed Secure Boot chain

The selected chain depends on the firmware state captured during setup.

### Direct firmware trust

When the firmware is in Setup Mode, sbctl keys are enrolled into db, KEK and PK,
with PK enrolled last. The boot path is:

    UEFI firmware -> signed rEFInd -> signed UKI -> Linux kernel and embedded initrd

The signed rEFInd loader is also placed at the architecture fallback path.
This path is used only in Setup Mode. It avoids shim and gives direct control of
PK/KEK/db, but makes local key backup and firmware recovery an administrator
responsibility.

### Shim and MOK trust

When the firmware is already in User Mode, setup does not replace its enrolled
platform keys. It prepares a shim/MOK path and imports the local db certificate
through `mokutil`. The user must confirm MOK enrollment at the next reboot.

The resulting path is:

    UEFI firmware -> shim -> MOK-authorized rEFInd payload -> signed UKI

MokManager is installed beside shim to support the enrollment step.
This path is used in User Mode. It preserves existing firmware ownership and
OEM/Microsoft compatibility, but adds shim and requires interactive MOK
enrollment. sbctl still signs local artifacts; MOK authorizes that identity
through shim instead of direct firmware db enrollment.

In both modes, rEFInd scans the generated configuration rather than booting a
traditional GRUB kernel entry. fwupd is configured for the detected trust path,
and the selected EFI executables are signed and verified during setup.

## UKI selection

UKIs are stored as `/boot/efi/EFI/Linux/<entry-token>-<kernel-version>.efi`.
The exact prefix is derived by the installed generator. The rEFInd hook sorts
kernel versions in descending version order, makes the newest UKI the main
entry, and exposes older valid UKIs in a submenu.

Each UKI embeds the kernel, initrd, command line, OS metadata, version, splash,
PCR public key and PCR signature. The generator rejects artifacts that fail the
db signature check, lack required PE sections, contain the wrong kernel version
or omit the installed snapshot-menu content when that feature is configured.

## Early userspace sequence

For a normal installed boot:

1. The firmware validates the direct loader or shim.
2. rEFInd launches a signed UKI.
3. The UKI starts the embedded kernel and dracut initramfs with its embedded
   command line.
4. The snapshot input listener watches TTY1 for Alt+B for five seconds when the
   module is enabled.
5. The listener is stopped before cryptsetup needs input, releasing all grabbed
   devices.
6. systemd/cryptsetup unlocks the LUKS root using an available method: TPM2 when
   enrolled and policy-valid, otherwise a retained password or recovery method.
7. dracut mounts `@ubuntu/@` and switches to the installed system.

The kernel command line keeps
`rd.luks.options=tpm2-device=auto,tpm2-measure-pcr=yes,tpm2-pin=yes` even when
the current TPM token does not use a PIN. This is intentional and allows future
PIN enrollment without regenerating every UKI.

## Unique feature: snapshot boot branch

If Alt+B is detected, the listener creates a request marker. After the LUKS
block device is available but before the real root mount, the snapshot hook:

1. mounts the Btrfs top level read-only;
2. lists the current system and root snapshots for the active suite at
   `@$suite/@/.snapshots/<number>/snapshot`;
3. obtains descriptions lazily from Snapper metadata;
4. optionally asks for the configured selector PIN;
5. rejects a snapshot without `/usr/lib/modules/<running-kernel>`;
6. mounts the chosen snapshot read-only as the new root;
7. enables dracut's in-memory overlay through
   `/etc/cmdline.d/99-snapshot.conf`.

The menu includes the current system, numbered snapshots, lazily loaded Snapper
metadata and descriptions, pagination and cancellation. Current defaults use
TTY1, Alt+B, a five-second window, 20 entries per page and 24-character
descriptions. Optional PIN protection allows three attempts and at most 12
characters.

Use Up/Down or `j`/`k` to select, Left/Right or `h`/`l` to change page, Enter
to boot and Ctrl+C to cancel snapshot selection and boot the current system.

The overlay supplies ephemeral writes while the selected snapshot remains
unchanged. Selecting the current system, cancelling, entering an invalid choice,
failing PIN authentication or encountering a menu error returns to normal root
boot.

The selector PIN is not a disk-unlock credential. Its salted hash is embedded
in the initramfs, and the current-system entry does not require it.

The separate home profile stores snapshots below
`@$suite/@home/.snapshots/<number>/snapshot`. They are not selectable boot roots.
Because every suite is a top-level sibling such as `@noble` or `@resolute`, each
distribution has independent root and home snapshot histories.

## TPM enrollment lifecycle

Initial installation only writes TPM configuration and installs commands. It
does not change LUKS tokens.

After booting the installed system, enrollment is explicit:

- `setup.sh --setup-tpm-luks-auto-unlock` invokes the installed `tpm-enroll`;
- the deprecated misspelled option ending in `_ulock` is still accepted;
- `setup.sh --seal-luks-disk-tpm` invokes `tpm-reseal --wipe-all-tpm2`;
- the standalone commands may be called directly after the repository is
  removed.

Enrollment creates a LUKS header backup before changing tokens. Ordinary
enrollment preserves existing tokens and recovery access. Resealing replaces
TPM2 tokens only after the explicit wipe acknowledgement and leaves password and
recovery keyslots intact.

For PIN-protected automatic unlock, set `TPM_USE_PIN="true"` in `/etc/tpm.conf`
before enrollment. Early boot will request the PIN before TPM key release. This
adds protection against theft of the complete machine but prevents unattended
boot; retain a tested LUKS password or recovery method. Both modes keep
`tpm2-pin=yes` in the UKI command line.
