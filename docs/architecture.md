# Architecture

This document owns component boundaries and installed artifacts. See
`boot-flow.md` for sequencing, `invariants.md` for constraints and `testing.md`
for verification.

## System boundary

The project converts a fresh Ubuntu Ubiquity installation from its live session
or a fresh Kali installation selected by the wizard. The default device layout
is:

| Device | Initial role | Result |
| --- | --- | --- |
| `/dev/sda1` | optional rescue reserve | FAT live system plus ext4 `writable` when enabled |
| `/dev/sda2` | FAT32 ESP at `/boot/efi` | label `ESP`; rEFInd, UKIs, fwupd and public certificates |
| `/dev/sda3` | unencrypted Btrfs `/` | in-place LUKS2 container exposed as `/dev/mapper/root` |

Device names are configurable. Ubuntu discovery expects the installed root at
`/target`, the ESP at `/target/boot/efi` and an optional separate boot at
`/target/boot`. Kali setup can mount those configured filesystems itself.
`/cdrom` supplies the Ubuntu live rescue source; rescue creation is disabled by
the Kali installation flow.

Installed persistent data and swap live inside LUKS2. The ESP and optional
rescue environment are outside that encryption boundary. A migrated old boot
partition is unused afterward unless explicitly reformatted for rescue.

## Orchestrator and framework

`setup.sh` owns the configuration wizard and the outer live/inner chroot split.
The outer phase performs storage conversion and optional rescue creation; the
inner phase installs Secure Boot, snapshots, UKIs and optional TPM support.
Successful completion restores temporary resolver/service-policy files but
leaves target mounts and `/dev/mapper/root` open.

Shared repository code is limited to:

- `lib/log.sh`: colored, namespaced logging and summaries;
- `lib/common.sh`: shared validation and lifecycle helpers;
- `lib/tui.sh`: input, password, single/multiple selection and toggles.

Domain policy remains in its subsystem. The repository copy placed in the
target is installation input, not a runtime dependency.

## Storage subsystem

`btrfs-root/scripts/btrfs-root-setup` coordinates exact-device/mount checks,
ESP labelling, subvolume conversion, in-place LUKS2 encryption and fstab/
crypttab generation.

Each suite is a top-level sibling container:

```text
@$suite/
├── @
├── @home
├── @cache
├── @log
├── @tmp
├── @libvirt
├── @docker
└── @swap/swapfile
```

For example, `@noble`, `@resolute` and `@kali` can coexist directly below Btrfs
top level.
Root snapshots are under `@$suite/@/.snapshots`; home snapshots are under
`@$suite/@home/.snapshots`.

If `boot_dev` is configured, its content is copied to `@$suite/@/boot`, checked
and the old `/boot` mount is omitted from the regenerated fstab. The partition
is preserved unless selected for rescue. LUKS conversion reserves 32 MiB, uses
Argon2id with configurable `iter_time` (milliseconds), opens mapper `root` and
then grows Btrfs to the available mapped size.

## Rescue subsystem

`rescue/script/install-rescue-live` is enabled by `install_rescue=yes` or run
independently with `setup.sh --install-rescue-live`. It requires exact target
confirmation and a GPT partition large enough for:

```text
max(7168 MiB, live-source size + 256 MiB) + 512 MiB
```

The leading range becomes FAT32 `UBUNTU_LIVE`; the released trailing range
becomes ext4 `writable`. Casper entries receive `persistent`. The wizard first
suggests an eligible `boot_dev`; otherwise it requests another partition.

## Secure Boot subsystem

`secure-boot/scripts/secure-boot-setup` coordinates key creation, the explicit
`sbctl`/`mok` choice, public-certificate export, rEFInd and fwupd.

- `sbctl`: direct loader and default `sbctl enroll-keys --microsoft` enrollment,
  possible only in firmware Setup Mode. Other states warn and skip enrollment.
- `mok`: shim, MokManager and `mokutil` import using the wizard PIN; firmware
  state never causes an automatic path change.

`EXPERIMENTAL_SBCTL_APPEND=true` alone enables the older partial append flow.
The upstream fallback executable is installed at `/usr/sbin/sbctl`.
Private keys stay below `/var/lib/sbctl/keys`; the ESP receives only `PK.pem`,
`KEK.pem`, `db.pem` and optional `db.cer` under `/boot/efi/EFI/keys`.

rEFInd, selected drivers, fwupd EFI files and UKIs are signed with the local db
identity and verified. Direct mode installs signed rEFInd at the fallback path;
MOK mode boots it through shim. `refind_themes.zip` is a required repository
artifact. The cleanup in `refind-setup` removes only validated EFI child trees
containing a regular `grubx64.efi`.

## Snapshot subsystem

`btrfs-snapshots-mng/` installs Snapper root/home profiles and optional dracut
module `92snapshot-menu`. A compiled evdev listener detects F12 before
cryptsetup, then exits and closes its input descriptors. The hook runs after
LUKS availability but before the real-root mount, offers compatible root
snapshots, mounts the selection read-only and uses an ephemeral overlay.
Failure or cancellation returns to normal boot.

Menu settings come from `/etc/snapshot-menu.conf` and are embedded in the
initramfs, so changes require `generate-uki --all`.

## UKI and kernel lifecycle

`uki/scripts/install-uki` configures kernel-install `layout=uki`, dracut and
ukify. UKIs are stored in `/boot/efi/EFI/Linux` and include kernel, initramfs,
command line, metadata, splash and PCR signature.

`debian-kernel-install-bridge` maps Debian postinst/postrm events to
`kernel-install add/remove`. Hook `99-refind-menu.install` atomically rebuilds
the menu newest-first: the newest kernel is the main entry and `Tab` exposes all
older versions. `generate-uki` validates signatures, PE sections, version and
snapshot-menu content, removing invalid artifacts.

## TPM and standalone artifacts

`tpm/scripts/install-tpm` writes `/etc/tpm.conf` but does not enroll LUKS.
`tpm-enroll` backs up the LUKS header, preserves recovery access and enrolls the
configured literal/signed PCR policy, optionally with a PIN. `tpm-reseal`
requires explicit TPM-token replacement acknowledgement; `tpm-status` is
read-only.

These installed commands contain their own logging and remain independent of
the repository:

- `/usr/sbin/generate-uki`;
- `/usr/sbin/tpm-enroll`;
- `/usr/sbin/tpm-reseal`;
- `/usr/sbin/tpm-status`.
