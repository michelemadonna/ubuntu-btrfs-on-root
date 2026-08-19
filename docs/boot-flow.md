# Installation and Boot Flow

Owns execution order; see `architecture.md` for components and `invariants.md`
for safety.

## Configuration discovery

Run `setup.sh` as root in a UEFI x86-64 live session. Without `setup.conf`, the
wizard selects `migration` or `new`.

Migration:

1. discovers exact root, ESP and optional boot at `/target`,
   `/target/boot/efi` and `/target/boot`;
2. uses mounted `/target` as `mp` and offers detected devices as defaults;
3. selects rescue, suggesting `boot_dev` only when live source, reserve and
   `writable` fit;
4. gathers suite, encryption, explicit Secure Boot path and options;
5. validates mode-0600 shell-quoted configuration, shows a non-secret summary
   and requires confirmation.

Missing exact `/target/boot` and unmounted `/target/cdrom` are non-fatal.

New installation requires root, amd64 and UEFI, verifies archive DNS reachability,
selects an unused whole disk and records its size/identity. It calculates ESP,
optional 10 GiB rescue, root and Windows ranges; gathers suite, LUKS,
hostname/localization and the initial sudo user/password. Root-all disables
Windows; insufficient Windows space returns to sizing.

## Live-session outer phase

### New installation

1. Install live tools and target archive keyring.
2. Revalidate disk identity, size and layout, then require its exact path.
3. Create GPT with `sgdisk`, settle udev and resolve unique GPT labels.
4. Format ESP and optional Windows/RE; create/open fresh LUKS2 root.
5. Create and mount Btrfs suite/data subvolumes and the configured swapfile,
   then run `debootstrap` with the minimum kernel, storage, locale and `sudo`
   packages.
6. Configure identity/localization, create the initial user in `sudo`, set its
   password, then write crypttab and atomic UUID-based fstab.
7. Persist resolved devices and join the common chroot phase.

### In-place migration

1. Validate configuration, devices, mounts and Btrfs root.
2. Unmount ESP and validate/apply FAT label `ESP`.
3. Create suite/data layout: Ubuntu snapshots the installed root into
   `@$suite/@`; Kali mounts top level with `subvolid=5`, migrates validated
   source subvolumes and removes them while preserving the new suite.
4. Copy/validate separate boot inside encrypted-root `/boot`, then unmount it.
5. Shrink/unmount Btrfs, reencrypt as LUKS2, open mapper `root`, remount and grow.
6. Write crypttab; regenerate fstab from Btrfs/ESP UUIDs with root, EFI, data
   and swap entries; prepare chroot mounts.
7. Copy the repository; invoke `setup.sh //inner` in an isolated mount namespace.

## Target-chroot inner phase

1. Start D-Bus, update packages and optionally pre-download dependencies.
2. Install initramfs cryptsetup support.
3. Detect firmware state and execute the selected Secure Boot path.
4. Install, sign and verify rEFInd/fwupd; export public certificates.
5. Configure Snapper and optional snapshot-menu dracut module.
6. Configure kernel-install, dracut and ukify; generate and validate UKIs.
7. Optionally install TPM support without enrolling a LUKS token.

After chroot, outer setup optionally creates rescue, validates the user, swapfile
and persistent storage files, restores resolver/policy files and leaves target
mounts and mapper `root` open. Failures after destructive storage operations use
the outer cleanup trap to retain those resources for diagnosis.

## Secure Boot branches

Detected `secure_boot_mode` affects warnings, never the selected
`secure_boot_enrollment`.

```text
sbctl: UEFI -> signed rEFInd -> signed UKI
mok:   UEFI -> shim -> MOK-authorized rEFInd -> signed UKI
```

Setup Mode runs `sbctl enroll-keys --microsoft`; other states sign but skip
enrollment. `EXPERIMENTAL_SBCTL_APPEND=true` selects partial append. MOK creates
a pending `mokutil` request completed in MokManager after reboot.

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

Newest boots normally; `Tab` exposes all older installed versions.

## Normal early boot

1. Firmware validates direct rEFInd or shim.
2. rEFInd launches the selected signed UKI.
3. The UKI starts its kernel and dracut initramfs.
4. Optional listener watches for B/b, then exits and closes input descriptors
   before cryptsetup credentials.
5. LUKS unlock uses a valid enrolled TPM token or retained password/recovery.
6. Without snapshot request, dracut mounts `@$suite/@` and switches root.

The command line always retains
`rd.luks.options=tpm2-device=auto,tpm2-measure-pcr=yes,tpm2-pin=yes`, including
PINless enrollment.

## Snapshot branch

When B/b precedes cryptsetup, its marker survives until LUKS. Plymouth keeps
`Snapshot menu ENABLED` through unlock; the pre-mount hook removes it, then:

1. mounts Btrfs top level read-only;
2. lists current root and compatible `@$suite/@/.snapshots/*/snapshot` entries;
3. optionally authenticates with the menu PIN;
4. rejects snapshots lacking modules for the running kernel;
5. mounts the selection read-only with an ephemeral overlay.

Current system, cancellation, invalid input, authentication failure or menu
failure continues normal boot. Home snapshots are excluded. Kali follows the
`Alt` prohibition in `invariants.md`.

## Maintenance flows

- `setup.sh --install-rescue-live`: install rescue from `RESCUE_SOURCE_DIR`
  (default `/cdrom`) onto `rescue_dev`.
- `setup.sh --setup-tpm-luks-auto-unlock`: invoke installed `tpm-enroll`.
- `setup.sh --seal-luks-disk-tpm`: invoke `tpm-reseal --wipe-all-tpm2`.
- `generate-uki --all`: rebuild all UKIs, embedding current
  `/etc/snapshot-menu.conf`.
