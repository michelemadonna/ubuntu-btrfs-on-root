# Installation and Boot Flow

This document owns execution order. Component details are in `architecture.md`;
safety requirements are in `invariants.md`.

## Configuration discovery

Run `setup.sh` as root after the fresh installation. For Ubuntu, remain in the
Ubiquity live session; for Kali, the wizard mounts the configured root, ESP and
optional separate `/boot`. If `setup.conf` is absent, the wizard first selects
`In Place Migration` or `New Setup or Migrate From another Disk`. In mode 2 it
selects a target disk first; if it contains a LUKS `ROOT` partition, the wizard
opens it temporarily, mounts Btrfs top-level, scans every directory for a
complete sbctl key hierarchy, and does not prompt for Secure
Boot enrollment or write rEFInd into the ESP.

The wizard then:

1. detects exact sources mounted at `/target`, `/target/boot/efi` and optional
   `/target/boot`;
2. uses `/target` as `mp` when mounted and offers detected devices as defaults;
3. asks whether rescue is required, suggesting `boot_dev` only when it can hold
   the live source, reserve and `writable` partition;
4. records suite, encryption, explicit Secure Boot path and optional features;
5. writes mode-0600 shell-quoted configuration, validates it, shows a
   non-secret summary and asks for final confirmation.

Before the normal source-disk prompts, the wizard selects a target disk. An
`ESP` plus `ROOT` GPT label selects cross-disk import: the target LUKS volume is
opened, a new `@$suite` tree is populated from the selected Btrfs source, and
existing target suite trees are preserved. A target without both labels enters
the destructive partitioning flow and stops after GPT, filesystems and LUKS2
initialization; the next execution performs the import.

An exact separate `/target/boot` mount may be absent. `/target/cdrom` is
unmounted only when it is a mount point; its absence is non-fatal.

## Live-session outer phase

1. Validate configuration, exact devices, mounts and Btrfs root type.
2. Unmount the ESP for FAT label `ESP` validation/application.
3. Build the suite layout and data subvolumes:
   - Ubuntu snapshots the installed root into `@$suite/@`;
   - Kali mounts Btrfs top level (`subvolid=5`), validates and copies its source
     subvolumes, then removes migrated top-level sources while preserving the
     new suite container.
4. If `boot_dev` exists, copy it into the new encrypted-root `/boot`, validate
   the copy and unmount the old boot.
5. Shrink Btrfs, unmount it, perform in-place LUKS2 reencryption, open mapper
   `root`, mount the new root and grow Btrfs.
6. Write crypttab and regenerate `fstab` from the Btrfs root and ESP UUIDs,
   including the root, EFI, data and swap entries; then prepare chroot bind
   mounts.

7. Copy the repository into the target and invoke `setup.sh //inner` in an
   isolated mount namespace.

## Target-chroot inner phase

1. Start D-Bus, update packages and optionally pre-download dependencies.
2. Install initramfs cryptsetup support.
3. Detect current firmware state and execute the user-selected Secure Boot path.
4. Install/sign/verify rEFInd and fwupd; export public certificates to the ESP.
5. Configure Snapper and the optional snapshot-menu dracut module.
6. Configure kernel-install, dracut and ukify; generate and validate UKIs.
7. Optionally install TPM support without enrolling a LUKS token.

After chroot return, the outer phase creates rescue only when requested. It then
restores temporary resolver/service-policy files. On success it deliberately
leaves target mounts and `/dev/mapper/root` open.

## Secure Boot branches

The detected `secure_boot_mode` informs warnings only; it never changes the
selected `secure_boot_enrollment`.

```text
sbctl: UEFI -> signed rEFInd -> signed UKI
mok:   UEFI -> shim -> MOK-authorized rEFInd -> signed UKI
```

For `sbctl`, Setup Mode permits `sbctl enroll-keys --microsoft`. Outside Setup
Mode, setup warns, creates/signs artifacts and skips enrollment without falling
back to MOK. `EXPERIMENTAL_SBCTL_APPEND=true` substitutes the partial append
flow. For MOK, `mokutil` creates a pending request and the user completes it in
MokManager at reboot.

## Kernel package lifecycle

```text
package postinst
  -> debian-kernel-install-bridge
  -> kernel-install add
  -> dracut + ukify + signing
  -> versioned UKI
  -> atomic rEFInd menu rebuild

package postrm
  -> debian-kernel-install-bridge
  -> kernel-install remove
  -> matching UKI removal
  -> atomic rEFInd menu rebuild
```

The menu sorts versions newest-first. Normal selection boots the newest UKI;
pressing `Tab` on it exposes all older installed versions.

## Normal early boot

1. Firmware validates direct rEFInd or shim.
2. rEFInd launches the selected signed UKI.
3. The UKI starts its kernel and dracut initramfs.
4. When installed, the listener watches for B/b, then exits and closes its
   input descriptors before cryptsetup can request credentials.
5. LUKS unlock uses a valid TPM token when enrolled, otherwise retained
   password/recovery access.
6. Without a snapshot request, dracut mounts `@$suite/@` and switches root.

The command line always retains
`rd.luks.options=tpm2-device=auto,tpm2-measure-pcr=yes,tpm2-pin=yes`, including
PINless enrollment.

## Snapshot branch

When B/b is detected during the pre-cryptsetup window, a request marker is
retained until LUKS is available. Plymouth keeps the `Snapshot menu ENABLED`
message visible during the LUKS prompt; the pre-mount hook removes it before
opening the selector. Before the real-root mount, the hook then:

1. mount the Btrfs top level read-only;
2. list current root and compatible `@$suite/@/.snapshots/*/snapshot` entries;
3. optionally authenticate selection with the menu PIN;
4. reject snapshots missing modules for the running kernel;
5. mount the chosen snapshot read-only and enable the ephemeral overlay.

Current-system selection, cancellation, invalid input, authentication failure
or menu failure follows normal boot. Home snapshots are never boot choices.
Kali follows the `Alt`-trigger prohibition defined in `invariants.md`.

## Maintenance flows

- `setup.sh --install-rescue-live`: runs only rescue installation using
  `rescue_dev` and `RESCUE_SOURCE_DIR` (default `/cdrom`).
- `setup.sh --setup-tpm-luks-auto-unlock`: invokes installed `tpm-enroll`.
- `setup.sh --seal-luks-disk-tpm`: invokes
  `tpm-reseal --wipe-all-tpm2`.
- `generate-uki --all`: rebuilds all installed UKIs, including changed
  `/etc/snapshot-menu.conf`.
