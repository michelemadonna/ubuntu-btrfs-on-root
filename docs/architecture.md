# Architecture

Owns boundaries/artifacts; see `boot-flow.md` for order,
`invariants.md` for constraints and `testing.md` for verification.

## System boundary

Project migrates a fresh Ubuntu/Kali installation or creates one with
`debootstrap`. Migration defaults to:

| Device | Initial role | Result |
| --- | --- | --- |
| `/dev/sda1` | optional rescue reserve | FAT live system plus ext4 `writable` when enabled |
| `/dev/sda2` | FAT32 ESP at `/boot/efi` | label `ESP`; rEFInd, UKIs, fwupd and public certificates |
| `/dev/sda3` | unencrypted Btrfs `/` | in-place LUKS2 container exposed as `/dev/mapper/root` |

Devices are configurable. Ubuntu discovery expects `/target`,
`/target/boot/efi` and optional `/target/boot`; Kali mounts configured
filesystems. `/cdrom` supplies Ubuntu rescue. Kali migration disables rescue;
new installation requires `casper/` when selected.

Persistent data and swap are inside LUKS2. ESP and rescue remain outside it. A
migrated boot partition is unused unless explicitly reformatted for rescue.

## Orchestrator and framework

`setup.sh` owns the wizard and live/chroot split. Live setup selects the
`migration`/`new` storage owner and rescue; chroot installs Secure Boot,
snapshots, UKIs and optional TPM. The target repository copy is installation
input, not a runtime dependency.

Shared repository code is limited to:

- `lib/log.sh`: namespaced logging and summaries;
- `lib/common.sh`: cross-subsystem validation and lifecycle helpers;
- `lib/tui.sh`: input, password, selection and toggles.

Domain policy stays local. Success restores temporary resolver/policy files and
leaves target mounts and mapper `root` open.

## Storage subsystems

`btrfs-root/scripts/btrfs-root-setup` owns migration validation, ESP labelling,
subvolumes, separate boot, in-place LUKS2 and atomic fstab/crypttab.

`new-install/scripts/new-install-setup` owns whole-disk validation/GPT, fresh
LUKS2/Btrfs, `debootstrap` and base setup. Unique GPT labels resolve paths for
`setup.sh`; both storage paths share chroot preparation.

GPT order is ESP, optional rescue, encrypted Linux root and, only with percentage
sizing, optional MSR/Windows/Windows RE. Rescue is one split-ready 10 GiB range.

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

`@noble`, `@resolute` and `@kali` coexist at Btrfs top level. Root/home
snapshots are `@$suite/@/.snapshots` and `@$suite/@home/.snapshots`.

Separate boot moves to `@$suite/@/boot`; fstab omits its old mount and preserves
the partition unless reused for rescue. Migration reserves 32 MiB for LUKS2,
uses millisecond Argon2id `iter_time`, opens `root` and grows Btrfs.

## Rescue subsystem

`rescue/script/install-rescue-live`, selected by `install_rescue=yes` or
`setup.sh --install-rescue-live`, owns exact-device confirmation and splitting a
large enough GPT partition:

```text
max(7168 MiB, live-source size + 256 MiB) + 512 MiB
```

It creates leading FAT32 `UBUNTU_LIVE` and trailing ext4 `writable` partitions;
Casper entries receive `persistent`. The wizard may suggest eligible
`boot_dev`, otherwise another partition is required.

## Secure Boot subsystem

`secure-boot/scripts/secure-boot-setup` coordinates the explicit `sbctl`/`mok`
path, key creation, public-certificate export, rEFInd and fwupd. Enrollment
policy is owned by `invariants.md`.

The upstream fallback executable is `/usr/sbin/sbctl`. Private keys remain in
`/var/lib/sbctl/keys`; the ESP receives only `PK.pem`, `KEK.pem`, `db.pem` and
optional `db.cer` below `/boot/efi/EFI/keys`.

rEFInd, selected drivers, fwupd EFI files and UKIs are signed and verified with
the local db identity. Direct mode uses signed fallback rEFInd; MOK mode reaches
it through shim. `refind_themes.zip` remains a required repository artifact.
`refind-setup` cleanup removes only validated EFI child trees containing regular
`grubx64.efi`.

## Snapshot subsystem

`btrfs-snapshots-mng/` owns Snapper root/home profiles and optional dracut module
`92snapshot-menu`. Its compiled evdev listener detects B/b before cryptsetup;
the hook selects compatible root snapshots after unlock but before real-root
mount, using a read-only snapshot and ephemeral overlay.

The module includes kernel `evdev`, exposing `/dev/input/event*` on modular Kali
kernels. Settings from
`/etc/snapshot-menu.conf` are embedded in initramfs; changes require
`generate-uki --all`.

## UKI and kernel lifecycle

`uki/scripts/install-uki` configures kernel-install `layout=uki`, dracut and
ukify. `/boot/efi/EFI/Linux` holds signed UKIs containing kernel, initramfs,
command line, metadata, splash and PCR signature.

`debian-kernel-install-bridge` maps Debian postinst/postrm to kernel-install.
`99-refind-menu.install` atomically rebuilds the newest-first menu;
`generate-uki` validates and removes invalid artifacts.

## TPM and standalone artifacts

`tpm/scripts/install-tpm` writes `/etc/tpm.conf` without enrollment.
`tpm-enroll` backs up the header, preserves recovery and enrolls configured
literal/signed PCR policy, optionally with PIN; `tpm-reseal` requires explicit
token-replacement acknowledgement; `tpm-status` is read-only.

These commands remain repository-independent:

- `/usr/sbin/generate-uki`;
- `/usr/sbin/tpm-enroll`;
- `/usr/sbin/tpm-reseal`;
- `/usr/sbin/tpm-status`.
